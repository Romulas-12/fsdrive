import Foundation
import FSDriveClientKit
import FSDriveCore

let usage = """
fsdrive \(FSDriveVersion.string) — command-line client for fsdrived

usage:
  fsdrive login URL --user NAME [--device NAME]
                                           sign in with a server account (password from FSDRIVE_PASSWORD or prompt)
  fsdrive login URL TOKEN [--device NAME]    use an access token instead
                                           --pin sha256/…: expect this server key instead of trusting the first one
  fsdrive logout                             sign this device out (the server forgets its token)
  fsdrive libs                               list libraries
  fsdrive create NAME                        create a library
  fsdrive sync LIBRARY FOLDER [--watch SECONDS]
                                           two-way sync of a library with a local folder

options:
  --config FILE    use another config file (default: ~/Library/Application Support/FSDrive/config.json)
"""

struct ClientConfig: Codable {
    var server: String
    var token: String
    var device: String
    /// Direct (home network) addresses, the announced one first.
    var endpoints: [String]?
    /// SSH tunnel through the gateway for use away from home (key kept beside the config).
    var external: ExternalAccess?
    /// The server's TLS key, pinned on first contact (see ServerTrust).
    var serverPin: String?
}

/// The device's SSH key and the pinned gateway key live next to the config file.
var sshDir: URL { URL(fileURLWithPath: configPath + ".ssh") }

func option(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fsdrive: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FSDrive").path
// Before 0.4 the client was called Rimfile and kept its config and state under that name.
let legacySupportDir = (supportDir as NSString).deletingLastPathComponent + "/Rimfile"
if !FileManager.default.fileExists(atPath: supportDir), FileManager.default.fileExists(atPath: legacySupportDir) {
    try? FileManager.default.moveItem(atPath: legacySupportDir, toPath: supportDir)
}
let configPath = option("config", in: &args).map { ($0 as NSString).expandingTildeInPath } ?? supportDir + "/config.json"
let stateDir = (configPath as NSString).deletingLastPathComponent + "/state"

func loadConfig() -> ClientConfig {
    guard let data = FileManager.default.contents(atPath: configPath),
          let config = try? JSONDecoder().decode(ClientConfig.self, from: data) else { fail("not logged in; run `fsdrive login URL TOKEN`") }
    return config
}

/// `trust` carries the pinned key; without one the first server to answer is pinned.
func client(_ config: ClientConfig, trust: ServerTrust? = nil) -> APIClient {
    let urls = (config.endpoints ?? [config.server]).compactMap(URL.init(string:))
    guard !urls.isEmpty else { fail("bad server URL \(config.server)") }
    let trust = trust ?? ServerTrust(pin: config.serverPin) { pin in
        // A config from before TLS learns the key on its next connection; keep it.
        var saved = loadConfig()
        saved.serverPin = pin
        try? saveConfig(saved)
        FileHandle.standardError.write(Data("fsdrive: pinned server key \(ServerPin.code(pin))\n".utf8))
    }
    return APIClient(endpoints: urls, token: config.token, trust: trust, tunnel: config.external.map { SSHTunnel(access: $0, dir: sshDir) })
}

func saveConfig(_ config: ClientConfig) throws {
    try FileIO.mkdirs(parentOf: configPath)
    try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: configPath), options: .atomic)
    chmod(configPath, 0o600)
}

func findLibrary(_ api: APIClient, _ name: String) async throws -> LibraryDTO {
    let nfc = name.precomposedStringWithCanonicalMapping
    guard let lib = try await api.libraries().first(where: { $0.name == nfc }) else { fail("no library named \(name)") }
    return lib
}

do {
    guard let command = args.first else {
        print(usage)
        exit(0)
    }
    switch command {
    case "login":
        let device = option("device", in: &args) ?? Host.current().localizedName ?? "Mac"
        let user = option("user", in: &args)
        let pinArg = option("pin", in: &args)
        guard args.count == (user == nil ? 3 : 2) else { fail("usage: fsdrive login URL --user NAME | fsdrive login URL TOKEN") }
        var config = ClientConfig(server: args[1], token: user == nil ? args[2] : "", device: device)
        // Signing in pins the server's key: from then on only this key is accepted.
        let trust = ServerTrust(pin: pinArg)
        print(try await client(config, trust: trust).ping())
        config.serverPin = trust.pin
        if let pin = trust.pin { print("Server key \(ServerPin.code(pin)) (compare with the FSDrive page in QTS)") }
        if let user {
            let password = ProcessInfo.processInfo.environment["FSDRIVE_PASSWORD"]
                ?? getpass("Пароль для \(user): ").map { String(cString: $0) } ?? ""
            let response = try await client(config).login(user: user, password: password, device: device)
            config.token = response.token
            if let access = response.external { config.external = try SSHTunnel.store(access, in: sshDir) }
        }
        let info = try? await client(config).info()
        config.endpoints = ServerAddresses.ordered(entered: config.server, info: info)
        if config.external == nil, info?.external == true {
            config.external = try SSHTunnel.store(try await client(config).externalAccess(), in: sshDir)
        }
        if let e = config.external { print("Away from home: SSH via \(e.user)@\(e.host):\(e.port)") }
        try saveConfig(config)
        print("Logged in as device \"\(device)\"")

    case "logout":
        let config = loadConfig()
        do { try await client(config).signOut() } catch { FileHandle.standardError.write(Data("fsdrive: server not told: \(error)\n".utf8)) }
        try? FileManager.default.removeItem(atPath: configPath)
        try? FileManager.default.removeItem(at: sshDir)
        print("Signed out")

    case "libs":
        for lib in try await client(loadConfig()).libraries() { print("\(lib.id)\t\(lib.name)\t(seq \(lib.latestSeq))") }

    case "create":
        guard args.count == 2 else { fail("usage: fsdrive create NAME") }
        let lib = try await client(loadConfig()).createLibrary(args[1])
        print("Created \(lib.name) (id \(lib.id))")

    case "sync":
        let watch = option("watch", in: &args).flatMap(Double.init)
        guard args.count == 3 else { fail("usage: fsdrive sync LIBRARY FOLDER") }
        let config = loadConfig()
        let api = client(config)
        let lib = try await findLibrary(api, args[1])
        try FileIO.mkdirs((args[2] as NSString).expandingTildeInPath)
        let dir = FileIO.canonical(args[2])
        let key = Data(SHA256.hash(data: Data("\(config.server)|\(lib.id)|\(dir)".utf8))).hex.prefix(16)
        let state = try ClientState(path: "\(stateDir)/\(key).sqlite")
        let engine = SyncEngine(api: api, libId: lib.id, dir: dir, state: state, device: config.device)
        repeat {
            do {
                let s = try await engine.syncOnce()
                if !s.isEmpty || watch == nil { logLine("\(lib.name): \(s.text)") }
            } catch {
                if watch == nil { throw error }
                logLine("sync failed, will retry: \(error)")
            }
            if let watch { try await Task.sleep(nanoseconds: UInt64(watch * 1_000_000_000)) }
        } while watch != nil

    default:
        print(usage)
        exit(2)
    }
} catch {
    fail("\(error)")
}
