import Foundation
import FSDriveCore
#if canImport(os)
import os
#endif

/// Away from home the server is reached through an SSH tunnel to the gateway:
/// `ssh -N -L 127.0.0.1:<port>:<server>` with this device's key, and HTTP then goes to
/// the local end. The gateway allows nothing but this one forward.
public final class SSHTunnel: @unchecked Sendable {
    public let access: ExternalAccess
    let keyPath: String
    let knownHostsPath: String
    /// Supplies the private key when it is kept elsewhere (the macOS Keychain); nil
    /// means it lives in `keyPath`.
    let keySource: (@Sendable () -> String?)?
    private let lock = NSLock()
    private var process: Process?
    /// Write end of the watchdog's stdin: it closes when this process dies.
    private var lifeline: Pipe?
    private var port: Int?
    /// The start in progress, shared by every request that needs the tunnel meanwhile:
    /// parallel starts would race on the key file and on the gateway.
    private var starting: Task<URL, Error>?

    /// `dir` holds the pinned gateway host key and, without `key`, the device key
    /// (id_ed25519). With `key`, the key is written there only while ssh starts.
    public init(access: ExternalAccess, dir: URL, key: (@Sendable () -> String?)? = nil) {
        self.access = access
        keySource = key
        keyPath = dir.appendingPathComponent("id_ed25519").path
        knownHostsPath = dir.appendingPathComponent("known_hosts").path
    }

    /// Writes the private key handed out by the server (mode 0600, as ssh requires) and
    /// returns the access details without it.
    public static func store(_ access: ExternalAccess, in dir: URL) throws -> ExternalAccess {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var kept = access
        if let key = access.privateKey {
            try writeKey(key, to: dir.appendingPathComponent("id_ed25519").path)
        }
        kept.privateKey = nil
        return kept
    }

    static func writeKey(_ key: String, to path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        try key.write(toFile: path, atomically: false, encoding: .utf8)
        chmod(path, 0o600)
    }

    public static func remove(in dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Base URL through the tunnel, starting ssh if it is not running.
    public func localURL() async throws -> URL {
        let task: Task<URL, Error> = lock.withLock {
            if process?.isRunning == true, let port {
                let url = URL(string: "https://127.0.0.1:\(port)")!
                return Task { url }
            }
            if let starting { return starting }
            let task = Task { try await self.start() }
            starting = task
            return task
        }
        defer { lock.withLock { if starting == task { starting = nil } } }
        do {
            return try await task.value
        } catch {
            Self.report(error)
            throw error
        }
    }

    private func start() async throws -> URL {
        let port = try Self.freePort()
        // The pinned gateway key goes down before every start: the folder may have been
        // cleared since (signing out removes it), and ssh must never meet an empty file.
        try FileManager.default.createDirectory(atPath: (knownHostsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let host = access.port == 22 ? access.host : "[\(access.host)]:\(access.port)"
        try "\(host) \(access.hostKey)\n".write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
        // A key from the Keychain sits on disk only until ssh has authenticated, in a file
        // of its own: the app and its Finder extension each run a tunnel, and one must
        // not delete the key while the other is signing in with it.
        var identity = keyPath
        if let keySource {
            guard let key = keySource() else { throw APIError(status: 0, message: "SSH: no device key in the Keychain") }
            identity = keyPath + "-" + UUID().uuidString
            try Self.writeKey(key, to: identity)
        }
        defer { if keySource != nil { try? FileManager.default.removeItem(atPath: identity) } }
        let p = Process()
        // ssh outlives a parent that is killed (macOS stops the Finder extension, the
        // app is updated) and would stay behind as an orphan. A small shell watches a
        // pipe from this process instead: when the pipe closes, the tunnel ends.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // UserKnownHostsFile takes a space-separated list, and the app's folder is in
        // "Group Containers": the path is quoted so ssh reads it as one file.
        p.arguments = ["-c", Self.watchdog, "sh",
            "-F", "/dev/null", "-N",
            "-i", identity, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-L", "127.0.0.1:\(port):\(access.target)",
            "-p", String(access.port), "\(access.user)@\(access.host)",
        ]
        let errors = Pipe()
        let line = Pipe()
        p.standardError = errors
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = line
        try p.run()
        lock.withLock {
            process = p
            lifeline = line
            self.port = port
        }
        // Ready once the local end accepts connections; give up if ssh exits first.
        for _ in 0..<150 {
            if !p.isRunning {
                let message = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                // The pinned key is public; naming it makes a host key mismatch obvious.
                let pinned = (try? String(contentsOfFile: knownHostsPath, encoding: .utf8)) ?? ""
                throw APIError(status: 0, message: "SSH: \(message.trimmingCharacters(in: .whitespacesAndNewlines)) [pinned: \(pinned.trimmingCharacters(in: .whitespacesAndNewlines))]")
            }
            if Self.accepts(port) { return URL(string: "https://127.0.0.1:\(port)")! }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        p.terminate()
        throw APIError(status: 0, message: "SSH: no tunnel after 15 s")
    }

    /// Why the tunnel did not come up, for Console (the clients fall back quietly).
    private static func report(_ error: Error) {
        #if canImport(os)
        Logger(subsystem: "com.romulas.fsdrive", category: "tunnel").error("\(String(describing: error), privacy: .public)")
        #else
        logLine("tunnel: \(error)")
        #endif
    }

    public func stop() {
        lock.withLock {
            process?.terminate()
            process = nil
            lifeline = nil
        }
    }

    deinit { process?.terminate() }

    /// Runs ssh with the arguments given and ends it when stdin reaches EOF (the parent
    /// is gone) or when the shell itself is told to stop. stdin is passed on as fd 3:
    /// a background job of a non-interactive shell would otherwise read /dev/null.
    private static let watchdog = """
        exec 3<&0
        /usr/bin/ssh "$@" </dev/null & s=$!
        { read -r _ <&3; kill $s 2>/dev/null; } & w=$!
        trap 'kill $s 2>/dev/null' TERM INT
        wait $s
        kill $w 2>/dev/null
        """

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw APIError(status: 0, message: "no free local port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func accepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
