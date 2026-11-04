import Foundation
import Hummingbird
import HummingbirdTLS
import FSDriveCore

let usage = """
fsdrived \(FSDriveVersion.string) — file sync server that keeps your files as plain folders

usage:
  fsdrived init   --root DIR [--owner NAME]       create the data folder and an access token
  fsdrived serve  --root DIR [--host H] [--port P]
  fsdrived import --root DIR --name NAME --path FOLDER
                                                 index an existing folder as a library (no files move)
  fsdrived scan   --root DIR                       re-index all libraries once and exit
  fsdrived relocate --root DIR --from OLDDIR       the data folder was moved from OLDDIR: update its paths
"""

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fsdrived: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
guard let rootArg = option("root", in: args) else { fail("--root is required\n\n\(usage)") }
try? FileIO.mkdirs((rootArg as NSString).expandingTildeInPath)
let root = FileIO.canonical(rootArg)

do {
    switch command {
    case "init":
        try FileIO.mkdirs(root + "/files")
        _ = try Store(root: root)
        if FileManager.default.fileExists(atPath: ServerConfig.path(root: root)) { fail("already initialized: \(root)") }
        var rng = SystemRandomNumberGenerator()  // arc4random / getrandom: cryptographically secure
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let config = ServerConfig(token: Data(bytes).hex, owner: option("owner", in: args) ?? NSUserName())
        try config.save(root: root)
        print("Initialized \(root)")
        print("Files live in \(root)/files/\(config.owner)/ — open it in Finder any time.")
        print("Access token (keep it secret): \(config.token)")

    case "import":
        guard let name = option("name", in: args), let path = option("path", in: args) else { fail("--name and --path are required") }
        let config = try ServerConfig.load(root: root)
        let store = try Store(root: root)
        let dir = FileIO.canonical(path)
        let lib = try await store.createLibrary(name: name, dir: dir, owner: config.owner)
        print("Library \(lib.name) (id \(lib.id)) -> \(dir). Indexing…")
        await Scanner(store: store).scan(try await store.library(lib.id))

    case "scan":
        let store = try Store(root: root)
        await Scanner(store: store).scanAll()

    case "relocate":
        guard let from = option("from", in: args) else { fail("--from is required") }
        let store = try Store(root: root)
        try await store.relocateRoot(from: from)
        print("Paths under \(from) now point to \(root)")

    case "serve":
        let config = try ServerConfig.load(root: root)
        let store = try Store(root: root)
        let scanner = Scanner(store: store)
        let transfers = Transfers(store: store, limiter: Limiter(config.maxConcurrentTransfers), activity: Activity())
        let host = option("host", in: args) ?? "127.0.0.1"
        let port = Int(option("port", in: args) ?? "") ?? 8740
        let router = buildRouter(store: store, transfers: transfers, scanner: scanner, config: config, port: port)
        // TLS only, also inside the home network: clients pin this server's key.
        let identity = try TLSIdentity.loadOrCreate(root: root)
        let app = Application(router: router, server: try .tls(.http1(), tlsConfiguration: try identity.serverConfiguration()),
                              configuration: .init(address: .hostname(host, port: port), serverName: "fsdrived"))

        Task.detached(priority: .background) {
            do { try await store.renameLegacyFolders() } catch { logLine("folders from before the rename: \(error)") }
            await provisionAllowed(store: store, scanner: scanner)
            while true {
                await scanner.scanAll()
                await store.dropStaleUploads(olderThan: 7 * 24 * 3600)
                do { try await store.pruneIdleDevices() } catch { logLine("devices: \(error)") }
                try? await Task.sleep(nanoseconds: UInt64(config.scanIntervalSeconds) * 1_000_000_000)
            }
        }
        logLine("fsdrived \(FSDriveVersion.string) serving \(root) on https://\(host):\(port), key \(ServerPin.code(identity.pin))")
        try await app.runService()

    default:
        print(usage)
        exit(2)
    }
} catch {
    fail("\(error)")
}
