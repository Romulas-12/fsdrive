import Foundation
import FSDriveCore

public struct APIError: Error, CustomStringConvertible {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var description: String { "HTTP \(status): \(message)" }
}

/// HTTP client for fsdrived. Bulk downloads are streamed through a delegate straight to
/// disk; nothing is buffered beyond what URLSession hands over.
public final class APIClient: @unchecked Sendable {
    public let token: String
    let session: URLSession
    let selector: EndpointSelector
    /// Which server certificate is accepted; holds the pin learned on first contact.
    public let trust: ServerTrust

    public convenience init(base: URL, token: String, trust: ServerTrust = ServerTrust(pin: nil)) {
        self.init(endpoints: [base], token: token, trust: trust)
    }

    /// `endpoints`: direct (home network) addresses in order of preference. `tunnel`:
    /// the SSH route used when none of them answers. The client switches by itself.
    /// `startDelay`: seconds after the program starts before the first choice of route
    /// (see EndpointSelector).
    /// `trust`: the pinned server key (see ServerTrust); every request, the route checks
    /// included, goes through it.
    public init(endpoints: [URL], token: String, trust: ServerTrust = ServerTrust(pin: nil), tunnel: SSHTunnel? = nil,
                startDelay: TimeInterval = 0) {
        selector = EndpointSelector(endpoints: endpoints.map(\.upgradedToTLS), tunnel: tunnel, startDelay: startDelay)
        self.token = token
        self.trust = trust
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    /// The address requests go to now; nil until the first request.
    public var activeEndpoint: URL? { selector.active }
    /// True inside the home network (direct connection), false through the proxy.
    public var isDirect: Bool { selector.isDirect }

    /// Runs `body` against the current address; if that address turns out to be
    /// unreachable (e.g. the Mac just left home), picks again and retries once.
    private func withEndpoint<T>(_ body: (URL) async throws -> T) async throws -> T {
        let first = await selector.base(session: session)
        do {
            return try await body(first)
        } catch where EndpointSelector.isUnreachable(error) {
            selector.invalidate()
            let second = await selector.base(session: session)
            guard second != first else { throw error }
            return try await body(second)
        }
    }

    private func request(_ base: URL, _ method: String, _ path: String, query: [String: String] = [:]) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? String(decoding: data, as: UTF8.self)
            throw APIError(status: status, message: message)
        }
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }

    public func call<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: (some Encodable)? = nil as String?) async throws -> T {
        let encoded = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await withEndpoint { base in
            var req = request(base, method, path, query: query)
            if let encoded {
                req.httpBody = encoded
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return try await session.data(for: req)
        }
        try Self.check(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func ping() async throws -> String {
        let (data, response) = try await withEndpoint { try await session.data(for: request($0, "GET", "v1/ping")) }
        try Self.check(data, response)
        return String(decoding: data, as: UTF8.self)
    }

    /// Exchanges a QTS user name and password for a token for this device.
    public func login(user: String, password: String, device: String) async throws -> LoginResponse {
        try await call("POST", "v1/login", body: LoginRequest(user: user, password: password, device: device))
    }

    /// Ends this device's token (and its gateway key) on the server.
    public func signOut() async throws {
        let (data, response) = try await withEndpoint { try await session.data(for: request($0, "DELETE", "v1/devices/self")) }
        try Self.check(data, response)
    }

    /// Asks for this device's SSH key for the external connection (at home only).
    public func externalAccess() async throws -> ExternalAccess {
        try await call("POST", "v1/devices/self/ssh-key")
    }

    /// Where the server can be reached (home network and internet); no token needed.
    public func info() async throws -> ServerInfo {
        try await call("GET", "v1/info")
    }

    public func libraries() async throws -> [LibraryDTO] {
        let r: LibrariesResponse = try await call("GET", "v1/libs")
        return r.libraries
    }

    public func createLibrary(_ name: String) async throws -> LibraryDTO {
        try await call("POST", "v1/libs", body: CreateLibraryRequest(name: name))
    }

    public func changes(lib: Int64, since: Int64) async throws -> ChangesResponse {
        try await call("GET", "v1/libs/\(lib)/changes", query: ["since": "\(since)", "limit": "1000"])
    }

    public func tree(lib: Int64) async throws -> TreeResponse {
        try await call("GET", "v1/libs/\(lib)/tree")
    }

    public func children(lib: Int64, parent: Int64?) async throws -> TreeResponse {
        try await call("GET", "v1/libs/\(lib)/children", query: parent.map { ["parent": "\($0)"] } ?? [:])
    }

    public func item(lib: Int64, id: Int64) async throws -> NodeDTO {
        try await call("GET", "v1/libs/\(lib)/items/\(id)")
    }

    public func manifest(lib: Int64, version: Int64) async throws -> ManifestResponse {
        try await call("GET", "v1/libs/\(lib)/versions/\(version)/manifest")
    }

    public func op(lib: Int64, _ op: OpRequest) async throws -> OpResponse {
        try await call("POST", "v1/libs/\(lib)/ops", body: op)
    }

    public func createUpload(lib: Int64, _ req: CreateUploadRequest) async throws -> CreateUploadResponse {
        try await call("POST", "v1/libs/\(lib)/uploads", body: req)
    }

    public func commit(uploadId: String) async throws -> CommitResponse {
        try await call("POST", "v1/uploads/\(uploadId)/commit")
    }

    public func putChunk(uploadId: String, hash: String, data: Data) async throws {
        let (body, response) = try await withEndpoint { base in
            var req = request(base, "PUT", "v1/uploads/\(uploadId)/chunks/\(hash)")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            return try await session.upload(for: req, from: data)
        }
        try Self.check(body, response)
    }

    /// Streams the requested byte ranges of a version; `onData` receives the bytes in
    /// order as they arrive.
    public func streamRanges(lib: Int64, version: Int64, ranges: [[Int64]], onData: @escaping (Data) throws -> Void) async throws {
        let base = await selector.base(session: session)
        var req = request(base, "POST", "v1/libs/\(lib)/versions/\(version)/ranges")
        req.httpBody = try JSONEncoder().encode(RangesRequest(ranges: ranges))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let delegate = StreamDelegate(onData: onData)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.continuation = cont
                let task = session.dataTask(with: req)
                task.delegate = delegate
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.task?.cancel()
        }
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let onData: (Data) throws -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var task: URLSessionDataTask?
    private var status = 0
    private var errorBody = Data()
    private var failure: Error?

    init(onData: @escaping (Data) throws -> Void) { self.onData = onData }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard status == 200 else {
            errorBody.append(data)
            return
        }
        do { try onData(data) } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if status != 200 {
            continuation?.resume(throwing: APIError(status: status, message: String(decoding: errorBody, as: UTF8.self)))
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
