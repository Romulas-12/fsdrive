import Foundation
import Network

/// A FSDrive server announced on the local network over Bonjour (_fsdrive._tcp).
struct DiscoveredServer: Identifiable, Hashable {
    var id: String { url }
    var name: String
    var model: String
    var url: String
}

/// "Find server": browses Bonjour for a few seconds and resolves each server to an
/// address. The NAS publishes the service through its own avahi (see fsdrive.sh).
@MainActor
final class ServerBrowser: ObservableObject {
    @Published private(set) var servers: [DiscoveredServer] = []
    @Published private(set) var searching = false

    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []

    func search(for seconds: Double = 5) {
        stop()
        servers = []
        searching = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_fsdrive._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in results.forEach { self?.resolve($0) } }
        }
        browser.start(queue: .main)
        self.browser = browser
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop() }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.forEach { $0.cancel() }
        resolving = []
        searching = false
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        var model = ""
        if case .bonjour(let txt) = result.metadata { model = txt.dictionary["model"] ?? "" }
        // Connecting is the simplest way to learn the address behind a service name.
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection,
                  case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return }
            // IPv4 literals come back with the interface attached ("10.0.0.2%en0").
            let ip = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
            let url = "https://\(ip.contains(":") ? "[\(ip)]" : ip):\(port.rawValue)"
            connection.cancel()
            Task { @MainActor in
                guard let self, !self.servers.contains(where: { $0.url == url }) else { return }
                self.servers.append(DiscoveredServer(name: name, model: model, url: url))
            }
        }
        connection.start(queue: .main)
        resolving.append(connection)
    }
}
