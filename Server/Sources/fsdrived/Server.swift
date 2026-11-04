import Foundation
import Hummingbird
import FSDriveCore

struct ServerConfig: Codable {
    var token: String
    var owner: String
    var scanIntervalSeconds: Int = 600
    /// Each transfer only streams into a file, so this bounds open files rather than
    /// CPU; it must exceed the client's parallel streams (see FileTransfer).
    var maxConcurrentTransfers: Int = 64

    static func path(root: String) -> String { root + "/.system/config.json" }

    static func load(root: String) throws -> ServerConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path(root: root)))
        return try JSONDecoder().decode(ServerConfig.self, from: data)
    }

    func save(root: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: ServerConfig.path(root: root)), options: .atomic)
        chmod(ServerConfig.path(root: root), 0o600)
    }
}

struct FSDriveContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    var principal: Principal?
    /// The device a user token belongs to.
    var deviceId: Int64?
    /// Address of the connecting peer (a proxy, when FSDrive sits behind one).
    let peerAddress: String?
    /// This server's own address on the connection: its IP in the home network.
    let localAddress: String?
    init(source: Source) {
        coreContext = .init(source: source)
        peerAddress = source.channel.remoteAddress?.ipAddress
        localAddress = source.channel.localAddress?.ipAddress
    }
    /// Upload manifests of very large files are big JSON documents.
    var maxUploadSize: Int { 256 << 20 }
}

/// Resolves the bearer token: the server token is the admin, any other must be a
/// device token of a user the admin still allows.
struct AuthMiddleware: RouterMiddleware {
    typealias Context = FSDriveContext
    let token: String
    let store: Store

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if ["/v1/ping", "/v1/login", "/v1/info"].contains(request.uri.path) { return try await next(request, context) }
        if request.uri.path.hasPrefix("/v1/gateway/") {
            // The SSH gateway has its own secret and reaches only the gateway endpoints.
            let secret = try await store.settings().gatewayToken
            guard !secret.isEmpty, constantTimeEqual(request.headers[.authorization] ?? "", "Bearer \(secret)") else {
                throw HTTPError(.unauthorized, message: "invalid gateway token")
            }
            return try await next(request, context)
        }
        guard let auth = request.headers[.authorization], auth.hasPrefix("Bearer ") else {
            throw HTTPError(.unauthorized, message: "missing token")
        }
        let presented = String(auth.dropFirst(7))
        var context = context
        if constantTimeEqual(presented, token) {
            context.principal = .admin
        } else if let (user, deviceId) = try await store.userForToken(presented) {
            guard try await store.isAllowed(user) else { throw HTTPError(.forbidden, message: "Доступ до FSDrive для \(user) вимкнено") }
            context.principal = .user(user)
            context.deviceId = deviceId
        } else {
            throw HTTPError(.unauthorized, message: "invalid token")
        }
        return try await next(request, context)
    }
}

/// Compares secrets in time that does not depend on where they first differ, so the
/// response time does not reveal how much of a guess was right.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
    for i in 0..<max(x.count, y.count) {
        diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return diff == 0 && x.count == y.count
}

/// File-system errors become a 500 with a short message; the details, which name
/// server paths, go to the log, where they would otherwise be lost.
struct FileErrorMiddleware: RouterMiddleware {
    typealias Context = FSDriveContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let e as FileIOError {
            logLine("\(request.method) \(request.uri.path): \(e)")
            throw HTTPError(.internalServerError, message: "Помилка файлової системи на сервері (подробиці в fsdrived.log)")
        }
    }
}

extension FSDriveContext {
    func requireAdmin() throws {
        guard case .admin = principal else { throw HTTPError(.forbidden, message: "admin only") }
    }

    /// Users reach only their own libraries; others look like they do not exist.
    func authorize(_ lib: Int64, _ store: Store) async throws {
        guard case .user(let name) = principal else { return }
        guard try await store.library(lib).owner == name else { throw HTTPError(.notFound, message: "library \(lib) not found") }
    }
}

struct UsersResponse: ResponseCodable { var users: [UserStatus] }
struct BlockedResponse: ResponseCodable { var entries: [LoginGuard.Entry] }
struct TokenRequest: Codable { var device: String }
struct TokenResponse: ResponseCodable { var token: String }

extension LibraryDTO: ResponseCodable {}
extension LibrariesResponse: ResponseCodable {}
extension ChangesResponse: ResponseCodable {}
extension TreeResponse: ResponseCodable {}
extension ManifestResponse: ResponseCodable {}
extension CreateUploadResponse: ResponseCodable {}
extension CommitResponse: ResponseCodable {}
extension OpResponse: ResponseCodable {}
extension NodeDTO: ResponseCodable {}
extension LoginResponse: ResponseCodable {}
extension FSDriveSettings: ResponseCodable {}
extension ServerInfo: ResponseCodable {}
extension ExternalAccess: ResponseCodable {}

func buildRouter(store: Store, transfers: Transfers, scanner: Scanner, config: ServerConfig, port: Int,
                 guard loginGuard: LoginGuard = LoginGuard())
    -> Router<FSDriveContext> {
    let router = Router(context: FSDriveContext.self)
    router.add(middleware: FileErrorMiddleware())
    router.add(middleware: AuthMiddleware(token: config.token, store: store))

    router.get("/v1/ping") { _, _ in "fsdrived \(FSDriveVersion.string)" }

    router.get("/v1/info") { _, context in
        let s = try await store.settings()
        // The server tells its own home-network address: the IP the request arrived on
        // (behind a proxy, the address the proxy forwards to). Nothing to configure, and
        // a new IP from the router is picked up by clients on their next refresh.
        let local = context.localAddress.map { ip in "https://\(ip.contains(":") ? "[\(ip)]" : ip):\(port)" }
        return ServerInfo(version: FSDriveVersion.string, localURL: local, external: s.externalReady, publicURL: s.activePublicURL)
    }

    /// What a device needs to connect from outside, with a fresh key. Refused through
    /// the gateway: keys are handed out at home only.
    @Sendable func externalAccess(_ context: FSDriveContext, user: String, deviceId: Int64) async throws -> ExternalAccess? {
        let s = try await store.settings()
        guard s.externalReady else { return nil }
        guard let peer = context.peerAddress, peer != s.gatewayAddress, let local = context.localAddress else {
            throw HTTPError(.forbidden, message: "Ключ для зовнішнього з'єднання видається лише в домашній мережі")
        }
        let pair = try await store.issueSSHKey(deviceId: deviceId, user: user)
        return ExternalAccess(host: s.gatewayHost, port: s.gatewayPort, user: s.gatewayUser, hostKey: s.gatewayHostKey,
                              target: "\(local.contains(":") ? "[\(local)]" : local):\(port)", privateKey: pair.privateKey)
    }

    router.post("/v1/devices/self/ssh-key") { _, context in
        guard case .user(let name) = context.principal, let deviceId = context.deviceId else {
            throw HTTPError(.forbidden, message: "device token required")
        }
        guard let access = try await externalAccess(context, user: name, deviceId: deviceId) else {
            throw HTTPError(.conflict, message: "Зовнішнє з'єднання вимкнено")
        }
        return access
    }

    /// Signing out on a device ends its token (and its gateway key) on the server too.
    router.delete("/v1/devices/self") { _, context in
        guard case .user(let name) = context.principal, let deviceId = context.deviceId else {
            throw HTTPError(.forbidden, message: "device token required")
        }
        try await store.revokeDevice(id: deviceId, user: name)
        return HTTPResponse.Status.noContent
    }

    // MARK: SSH gateway

    /// authorized_keys for the gateway's tunnel user: every allowed device's key, each
    /// limited to forwarding to this server and nothing else.
    router.get("/v1/gateway/authorized_keys") { _, context in
        let target = context.localAddress.map { "\($0.contains(":") ? "[\($0)]" : $0):\(port)" } ?? "127.0.0.1:\(port)"
        let lines = try await store.gatewayKeys().map { "restrict,port-forwarding,permitopen=\"\(target)\" \($0)" }
        return Response(status: .ok, headers: [.contentType: "text/plain"],
                        body: .init(byteBuffer: ByteBuffer(string: lines.joined(separator: "\n") + "\n")))
    }

    router.post("/v1/gateway/register") { request, context in
        let body = try await request.body.collect(upTo: 16 << 10)
        let hostKey = String(buffer: body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard hostKey.hasPrefix("ssh-"), hostKey.split(separator: " ").count >= 2 else {
            throw HTTPError(.badRequest, message: "expected the gateway host public key")
        }
        let key = hostKey.split(separator: " ").prefix(2).joined(separator: " ")
        try await store.registerGateway(hostKey: key, address: context.peerAddress ?? "")
        logLine("SSH gateway registered from \(context.peerAddress ?? "?")")
        return HTTPResponse.Status.noContent
    }

    router.post("/v1/login") { request, context in
        let req = try await request.decode(as: LoginRequest.self, context: context)
        let ip = clientAddress(request, peer: context.peerAddress, trusted: try await store.settings().trustedProxies)
        if let wait = await loginGuard.retryAfter(ip: ip, user: req.user) {
            let minutes = Int((wait / 60).rounded(.up))
            throw HTTPError(.tooManyRequests, headers: [.retryAfter: "\(Int(wait.rounded(.up)))"],
                            message: "Забагато невдалих спроб входу. Спробуйте через \(minutes) хв.")
        }
        await loginGuard.checks.acquire()
        let verdict = NAS.current.verify(user: req.user, password: req.password)
        await loginGuard.checks.release()
        switch verdict {
        case .ok:
            await loginGuard.succeeded(ip: ip, user: req.user)
        case .wrongPassword:
            logLine("login failed: user=\(req.user) from \(ip)")
            for blocked in await loginGuard.failed(ip: ip, user: req.user) {
                let what = blocked.hasPrefix("ip:") ? "адресу \(blocked.dropFirst(3))" : "вхід для \(blocked.dropFirst(5))"
                logLine("login blocked: \(blocked) for 15 min")
                nasLogWarning("[FSDrive] Забагато невдалих спроб входу: заблоковано \(what) на 15 хв")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)  // slows down password guessing
            throw HTTPError(.unauthorized, message: "Неправильне ім'я користувача або пароль")
        case .twoStep: throw HTTPError(.forbidden, message: "Двоетапна перевірка \(NAS.current.system) поки не підтримується")
        case .refused(let why): throw HTTPError(.forbidden, message: why)
        case .unavailable: throw HTTPError(.notImplemented, message: "Вхід за паролем працює лише на NAS (QNAP або Synology)")
        }
        guard try await store.isAllowed(req.user) else {
            throw HTTPError(.forbidden, message: "Адміністратор ще не дозволив \(req.user) користуватися FSDrive")
        }
        if let lib = try await store.provision(req.user) { Task.detached(priority: .background) { await scanner.scan(lib) } }
        let issued = try await store.issueToken(user: req.user, device: req.device)
        // Signing in from outside goes through the gateway with an existing key, so a new
        // key is only made here when the request comes from the home network.
        let s = try await store.settings()
        let atHome = context.peerAddress != nil && context.peerAddress != s.gatewayAddress
        let external = atHome ? try await externalAccess(context, user: req.user, deviceId: issued.deviceId) : nil
        return LoginResponse(token: issued.token, user: req.user, external: external)
    }

    router.get("/v1/libs") { _, context in
        switch context.principal {
        case .user(let name):
            if try await store.libraries(owner: name).isEmpty, let lib = try await store.provision(name) {
                Task.detached(priority: .background) { await scanner.scan(lib) }
            }
            return LibrariesResponse(libraries: try await store.libraries(owner: name))
        default:
            return LibrariesResponse(libraries: try await store.libraries())
        }
    }

    router.post("/v1/libs") { request, context in
        try context.requireAdmin()
        let req = try await request.decode(as: CreateLibraryRequest.self, context: context)
        return try await store.createLibrary(name: req.name, owner: config.owner)
    }

    router.get("/v1/libs/:lib/changes") { request, context in
        let lib = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(lib, store)
        let since = request.uri.queryParameters.get("since", as: Int64.self) ?? 0
        let limit = min(request.uri.queryParameters.get("limit", as: Int.self) ?? 1000, 5000)
        _ = try await store.library(lib)
        return try await store.changes(lib: lib, since: since, limit: limit)
    }

    router.get("/v1/libs/:lib/tree") { _, context in
        let lib = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(lib, store)
        return try await store.tree(lib: lib)
    }

    router.get("/v1/libs/:lib/children") { request, context in
        let lib = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(lib, store)
        return try await store.children(lib: lib, parent: request.uri.queryParameters.get("parent", as: Int64.self))
    }

    router.get("/v1/libs/:lib/items/:id") { _, context in
        let lib = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(lib, store)
        return try await store.item(lib: lib, id: try context.parameters.require("id", as: Int64.self))
    }

    router.post("/v1/libs/:lib/scan") { _, context in
        let libId = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(libId, store)
        await scanner.scan(try await store.library(libId))
        return HTTPResponse.Status.noContent
    }

    router.post("/v1/libs/:lib/ops") { request, context in
        let lib = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(lib, store)
        let req = try await request.decode(as: OpRequest.self, context: context)
        return try await store.apply(lib: lib, req)
    }

    router.get("/v1/libs/:lib/versions/:vid/manifest") { _, context in
        let lib = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(lib, store)
        let vid = try context.parameters.require("vid", as: Int64.self)
        guard let v = try await store.versionPath(vid), v.libId == lib else {
            throw HTTPError(.notFound, message: "version \(vid) is not available")
        }
        return ManifestResponse(size: v.manifest.size, contentHash: v.manifest.contentHash.hex, chunks: v.manifest.dto)
    }

    router.get("/v1/libs/:lib/versions/:vid/content") { _, context in
        try await context.authorize(try context.parameters.require("lib", as: Int64.self), store)
        return try await transfers.ranges(lib: try context.parameters.require("lib", as: Int64.self),
                                   versionId: try context.parameters.require("vid", as: Int64.self), ranges: nil)
    }

    router.post("/v1/libs/:lib/versions/:vid/ranges") { request, context in
        try await context.authorize(try context.parameters.require("lib", as: Int64.self), store)
        let req = try await request.decode(as: RangesRequest.self, context: context)
        return try await transfers.ranges(lib: try context.parameters.require("lib", as: Int64.self),
                                          versionId: try context.parameters.require("vid", as: Int64.self), ranges: req.ranges)
    }

    router.post("/v1/libs/:lib/uploads") { request, context in
        let lib = try context.parameters.require("lib", as: Int64.self)
        try await context.authorize(lib, store)
        let req = try await request.decode(as: CreateUploadRequest.self, context: context)
        let (session, missing) = try await store.createUpload(lib: lib, request: req)
        return CreateUploadResponse(uploadId: session.id, missing: missing.map(\.hex))
    }

    router.put("/v1/uploads/:id/chunks/:hash") { request, context in
        try await context.authorize(try await store.session(try context.parameters.require("id")).libId, store)
        try await transfers.receiveChunk(uploadId: try context.parameters.require("id"),
                                         hashHex: try context.parameters.require("hash"), body: request.body)
        return HTTPResponse.Status.noContent
    }

    router.post("/v1/uploads/:id/commit") { _, context in
        try await context.authorize(try await store.session(try context.parameters.require("id")).libId, store)
        return try await transfers.commit(uploadId: try context.parameters.require("id"))
    }

    // MARK: Admin (the NAS settings page)

    router.get("/v1/admin/settings") { _, context in
        try context.requireAdmin()
        return try await store.settings()
    }

    router.put("/v1/admin/settings") { request, context in
        try context.requireAdmin()
        try await store.saveSettings(try await request.decode(as: FSDriveSettings.self, context: context))
        await provisionAllowed(store: store, scanner: scanner)
        return UsersResponse(users: try await store.userStatuses())
    }

    router.get("/v1/admin/users") { _, context in
        try context.requireAdmin()
        return UsersResponse(users: try await store.userStatuses())
    }

    router.post("/v1/admin/users/:name/token") { request, context in
        try context.requireAdmin()
        let name = try context.parameters.require("name")
        guard try await store.isAllowed(name) else { throw HTTPError(.forbidden, message: "\(name) is not allowed") }
        if let lib = try await store.provision(name) { await scanner.scan(lib) }
        let device = try await request.decode(as: TokenRequest.self, context: context).device
        return TokenResponse(token: try await store.issueToken(user: name, device: device).token)
    }

    router.post("/v1/admin/users/:name/rebind") { _, context in
        try context.requireAdmin()
        if let lib = try await store.provision(try context.parameters.require("name"), rebind: true) { await scanner.scan(lib) }
        return UsersResponse(users: try await store.userStatuses())
    }

    router.get("/v1/admin/blocked") { _, context in
        try context.requireAdmin()
        return BlockedResponse(entries: await loginGuard.entries())
    }

    router.delete("/v1/admin/blocked") { request, context in
        try context.requireAdmin()
        guard let kind = request.uri.queryParameters.get("kind"), let value = request.uri.queryParameters.get("value") else {
            throw HTTPError(.badRequest, message: "kind and value required")
        }
        await loginGuard.unblock(kind: kind, value: value)
        return BlockedResponse(entries: await loginGuard.entries())
    }

    router.put("/v1/admin/users/:name/limits") { request, context in
        try context.requireAdmin()
        try await store.setLimits(try await request.decode(as: UserLimits.self, context: context), for: try context.parameters.require("name"))
        return UsersResponse(users: try await store.userStatuses())
    }

    router.delete("/v1/admin/devices/:id") { _, context in
        try context.requireAdmin()
        guard try await store.revokeDevice(id: try context.parameters.require("id", as: Int64.self)) else {
            throw HTTPError(.notFound, message: "Такого пристрою вже немає")
        }
        return UsersResponse(users: try await store.userStatuses())
    }

    router.delete("/v1/admin/users/:name/devices") { _, context in
        try context.requireAdmin()
        try await store.revokeDevices(user: try context.parameters.require("name"))
        return UsersResponse(users: try await store.userStatuses())
    }

    return router
}

/// Creates missing personal libraries for allowed users and indexes what is already
/// in their folders. Problems are recorded per user for the settings page.
func provisionAllowed(store: Store, scanner: Scanner) async {
    guard let names = try? await store.settings().allowedUsers else { return }
    for name in names {
        do {
            if let lib = try await store.provision(name) { await scanner.scan(lib) }
        } catch {
            logLine("provision \(name): \(error)")
            try? await store.recordProblem(name, (error as? HTTPError)?.body ?? "\(error)")
        }
    }
}
