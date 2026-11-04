import FileProvider
import Foundation
import FSDriveClientKit
import FSDriveCore

/// State shared by the menu bar app and the File Provider extension through the
/// App Group container.
enum Shared {
    static let appGroup = "BBBH2WC2K8.com.romulas.fsdrive"
    static let domainIdentifier = NSFileProviderDomainIdentifier("fsdrive")

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory
    }

    static var configURL: URL { container.appendingPathComponent("config.json") }
    static var pinnedURL: URL { container.appendingPathComponent("pinned.json") }
    static var pendingURL: URL { container.appendingPathComponent("pending-updates.json") }
    /// This Mac's SSH key and the pinned gateway host key (external connection).
    static var sshDir: URL { container.appendingPathComponent("ssh", isDirectory: true) }

    /// The Finder location. The sidebar shows the app's name; the server's address names
    /// the folder: ~/Library/CloudStorage/FSDrive-<server>.
    static var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: domainIdentifier, displayName: AccountConfig.load()?.displayHost ?? "FSDrive")
    }
}

struct AccountConfig: Codable, Equatable {
    var server: String
    /// Kept in the Keychain, never in config.json.
    var token: String
    var device: String
    var user: String?
    /// Direct (home network) addresses, the one the server announces first; nil for
    /// configs saved before automatic switching existed, which use `server` only.
    var endpoints: [String]?
    /// SSH tunnel through the gateway, used away from home; its key is in the Keychain.
    var external: ExternalAccess?
    /// The server's TLS key, pinned on first contact (see ServerTrust); a config from
    /// before TLS learns it on its next connection.
    var serverPin: String?

    init(server: String, token: String, device: String, user: String?) {
        self.server = server
        self.token = token
        self.device = device
        self.user = user
    }

    private enum CodingKeys: String, CodingKey { case server, token, device, user, endpoints, external, serverPin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decode(String.self, forKey: .server)
        // Present only in files written before the Keychain was used.
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        device = try c.decode(String.self, forKey: .device)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        endpoints = try c.decodeIfPresent([String].self, forKey: .endpoints)
        external = try c.decodeIfPresent(ExternalAccess.self, forKey: .external)
        serverPin = try c.decodeIfPresent(String.self, forKey: .serverPin)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(server, forKey: .server)
        try c.encode(device, forKey: .device)
        try c.encodeIfPresent(user, forKey: .user)
        try c.encodeIfPresent(endpoints, forKey: .endpoints)
        try c.encodeIfPresent(external, forKey: .external)
        try c.encodeIfPresent(serverPin, forKey: .serverPin)
    }

    static func load() -> AccountConfig? {
        guard let data = try? Data(contentsOf: Shared.configURL),
              var config = try? JSONDecoder().decode(AccountConfig.self, from: data) else { return nil }
        if config.token.isEmpty {
            config.token = Keychain.get(.token) ?? ""
        } else {
            // Older file with the token inside: move it to the Keychain.
            try? config.save()
        }
        migrateSSHKey()
        return config
    }

    func save() throws {
        if !token.isEmpty { try Keychain.set(token, for: .token) }
        try FileManager.default.createDirectory(at: Shared.container, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Shared.configURL, options: [.atomic, .completeFileProtection])
        chmod(Shared.configURL.path, 0o600)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: Shared.configURL)
        Keychain.remove(.token)
        Keychain.remove(.sshKey)
    }

    /// Keeps this Mac's SSH key from the server in the Keychain.
    static func storeSSHKey(_ access: ExternalAccess) throws -> ExternalAccess {
        if let key = access.privateKey { try Keychain.set(key, for: .sshKey) }
        var kept = access
        kept.privateKey = nil
        return try SSHTunnel.store(kept, in: Shared.sshDir)
    }

    /// A key file left by an older version moves into the Keychain. While a tunnel
    /// starts, the file is the Keychain copy and is removed again by the tunnel.
    private static func migrateSSHKey() {
        let file = Shared.sshDir.appendingPathComponent("id_ed25519")
        guard Keychain.get(.sshKey) == nil, let key = try? String(contentsOf: file, encoding: .utf8) else { return }
        do {
            try Keychain.set(key, for: .sshKey)
            try FileManager.default.removeItem(at: file)
        } catch {
            logLine("ssh key migration: \(error)")
        }
    }

    var api: APIClient? {
        let urls = (endpoints ?? [server]).compactMap(URL.init(string:))
        // A key learned here (first contact) is kept for the app and the Finder extension.
        let trust = ServerTrust(pin: serverPin) { pin in
            guard var saved = AccountConfig.load(), saved.serverPin == nil else { return }
            saved.serverPin = pin
            try? saved.save()
        }
        return urls.isEmpty ? nil : APIClient(endpoints: urls, token: token, trust: trust,
                                              tunnel: external.map { SSHTunnel(access: $0, dir: Shared.sshDir, key: { Keychain.get(.sshKey) }) },
                                              startDelay: 10)
    }

    /// The pinned key in the short form people compare, e.g. "3F9A-0C21-7B44-E810".
    var serverCode: String? { serverPin.map(ServerPin.code) }

    /// Name for Finder: the address the user typed, which does not change when the Mac
    /// moves between home and away.
    var displayHost: String { URL(string: server)?.host ?? "FSDrive" }
}

/// Item identifiers: the domain root lists libraries ("L<lib>"); everything inside a
/// library is "N<lib>-<fileId>", so identifiers survive renames and moves.
enum ItemID: Equatable {
    case root
    case workingSet
    case trash
    case library(Int64)
    case node(lib: Int64, id: Int64)

    init(_ identifier: NSFileProviderItemIdentifier) {
        switch identifier {
        case .rootContainer: self = .root
        case .workingSet: self = .workingSet
        case .trashContainer: self = .trash
        default:
            let raw = identifier.rawValue
            if raw.hasPrefix("L"), let lib = Int64(raw.dropFirst()) {
                self = .library(lib)
            } else if raw.hasPrefix("N"), let dash = raw.firstIndex(of: "-"),
                      let lib = Int64(raw[raw.index(after: raw.startIndex)..<dash]), let id = Int64(raw[raw.index(after: dash)...]) {
                self = .node(lib: lib, id: id)
            } else {
                self = .trash
            }
        }
    }

    var identifier: NSFileProviderItemIdentifier {
        switch self {
        case .root: return .rootContainer
        case .workingSet: return .workingSet
        case .trash: return .trashContainer
        case .library(let lib): return NSFileProviderItemIdentifier("L\(lib)")
        case .node(let lib, let id): return NSFileProviderItemIdentifier("N\(lib)-\(id)")
        }
    }

    var libId: Int64? {
        switch self {
        case .library(let lib), .node(let lib, _): return lib
        default: return nil
        }
    }
}

/// Items the user chose to "Keep Downloaded" (the extension reports them with an
/// eager content policy so macOS downloads them and never evicts them).
enum Pinned {
    static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: Shared.pinnedURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    static func set(_ identifier: NSFileProviderItemIdentifier, pinned: Bool) {
        var ids = load()
        if pinned { ids.insert(identifier.rawValue) } else { ids.remove(identifier.rawValue) }
        try? JSONEncoder().encode(Array(ids).sorted()).write(to: Shared.pinnedURL, options: .atomic)
        var pending = takePending()
        pending.insert(identifier.rawValue)
        try? JSONEncoder().encode(Array(pending)).write(to: Shared.pendingURL, options: .atomic)
    }

    /// Items whose local-only metadata (the pin) changed and must be re-reported to
    /// the system on the next working-set enumeration. Reading clears the list.
    static func takePending() -> Set<String> {
        guard let data = try? Data(contentsOf: Shared.pendingURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: Shared.pendingURL)
        return Set(ids)
    }
}
