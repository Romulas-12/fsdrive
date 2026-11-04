import Foundation
import Network
import FSDriveCore

/// Picks how to reach the server: directly inside the home network when it answers,
/// otherwise its internet address (HTTPS proxy or a port forwarded on the router), or
/// the SSH tunnel to the gateway. Re-checks after every network change
/// (other Wi-Fi, VPN, cable) and after a connection error, so a Mac that leaves home
/// switches over by itself.
final class EndpointSelector: @unchecked Sendable {
    /// Direct addresses in order of preference.
    let endpoints: [URL]
    /// Used when no direct address answers; nil without an external connection.
    let tunnel: SSHTunnel?
    private let lock = NSLock()
    private var current: URL?
    /// Away from home: on the tunnel or an internet address.
    private var viaTunnel = false
    private var chosenAt = Date.distantPast
    private var chosenGeneration = -1
    /// While away: when the home network was last tried in the background.
    private var lastDirectProbe = Date.distantPast

    /// Bumped by the path monitor whenever the Mac's network changes.
    private static let generationLock = NSLock()
    nonisolated(unsafe) private static var generation = 0
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { _ in
            generationLock.lock()
            generation += 1
            generationLock.unlock()
        }
        m.start(queue: DispatchQueue(label: "fsdrive.network-path"))
        return m
    }()

    /// No route is chosen sooner than this after the program starts. A freshly installed
    /// Mac app gets local network access a few seconds after launch; deciding earlier
    /// would put it on the tunnel at home.
    let startDelay: TimeInterval
    private static let processStart = Date()

    init(endpoints: [URL], tunnel: SSHTunnel?, startDelay: TimeInterval = 0) {
        self.endpoints = endpoints
        self.tunnel = tunnel
        self.startDelay = startDelay
        _ = Self.monitor
    }

    private static var currentGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    /// The address in use now, or nil before the first check.
    var active: URL? { lock.withLock { current } }

    /// True when talking to the server directly inside the home network.
    var isDirect: Bool { lock.withLock { !viaTunnel } }

    func invalidate() {
        lock.withLock { current = nil }
    }

    func base(session: URLSession) async -> URL {
        let (cached, fresh) = lock.withLock {
            (current, Self.currentGeneration == chosenGeneration && Date().timeIntervalSince(chosenAt) < 300)
        }
        if let cached, fresh || (endpoints.count == 1 && tunnel == nil) {
            probeDirectIfOnTunnel(session: session)
            return cached
        }
        if endpoints.count == 1 && tunnel == nil { return remember(endpoints[0], tunnel: !endpoints[0].isHomeAddress) }

        let wait = startDelay - Date().timeIntervalSince(Self.processStart)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        let generation = Self.currentGeneration
        for url in endpoints where await Self.answers(url, session: session) {
            tunnel?.stop()  // back home (or on an internet address): no tunnel needed
            return remember(url, tunnel: !url.isHomeAddress, generation: generation)
        }
        if let tunnel, let local = try? await tunnel.localURL(), await Self.answers(local, session: session) {
            return remember(local, tunnel: true, generation: generation)
        }
        // Nothing answered (offline): keep the last choice so errors name a real address.
        return remember(cached ?? endpoints[endpoints.count - 1], tunnel: false, generation: generation)
    }

    /// The tunnel or an internet address may have been picked during a short outage (or
    /// while macOS was still granting local network access): every 30 s the home addresses
    /// are tried in the background, and the first one that answers takes over.
    private func probeDirectIfOnTunnel(session: URLSession) {
        let due = lock.withLock { () -> Bool in
            guard viaTunnel, Date().timeIntervalSince(lastDirectProbe) > 30 else { return false }
            lastDirectProbe = Date()
            return true
        }
        guard due else { return }
        let direct = endpoints.filter { $0.isHomeAddress }
        Task {
            for url in direct where await Self.answers(url, session: session) {
                self.tunnel?.stop()
                _ = self.remember(url, tunnel: false)
                return
            }
        }
    }

    private func remember(_ url: URL, tunnel: Bool, generation: Int = EndpointSelector.currentGeneration) -> URL {
        lock.withLock {
            current = url
            viaTunnel = tunnel
            chosenAt = Date()
            chosenGeneration = generation
        }
        return url
    }

    /// A quick /v1/ping. Outside the home network the direct address either does not
    /// resolve or does not connect, so this fails fast.
    private static func answers(_ base: URL, session: URLSession) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("v1/ping"))
        req.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Errors meaning "this address is not reachable from here", worth trying another.
    static func isUnreachable(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .networkConnectionLost,
                .notConnectedToInternet, .secureConnectionFailed].contains(e.code)
    }
}

public enum ServerAddresses {
    /// Addresses to keep for a server, tried in this order: the home-network one it
    /// announces, the internet one if that mode is on (HTTPS proxy or forwarded port), then
    /// the one the user typed.
    public static func ordered(entered: String, info: ServerInfo?) -> [String] {
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        // Earlier servers announced http://; this one speaks TLS only.
        let tls = { (s: String) in s.hasPrefix("http://") ? "https://" + s.dropFirst("http://".count) : s }
        var list = [info?.localURL, info?.publicURL].compactMap { $0 }.map(clean).map(tls).filter { !$0.isEmpty }
        if !list.contains(tls(clean(entered))) { list.append(tls(clean(entered))) }
        return list
    }
}
