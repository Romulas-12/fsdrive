import Foundation
import Hummingbird
import FSDriveCore

/// Where personal libraries live, chosen by the admin on the QTS settings page.
struct FSDriveSettings: Codable, Equatable {
    enum StorageMode: String, Codable { case home, folder }
    enum FolderNaming: String, Codable { case name, uid }

    /// `home`: <home>/FSDrive for each user. `folder`: <folderPath>/<user name or uid>.
    var storageMode: StorageMode = .home
    var folderPath: String = "/share/FSDrive"
    var folderNaming: FolderNaming = .name
    /// QNAP users allowed to use FSDrive. Nobody until the admin picks.
    var allowedUsers: [String] = []
    /// How devices reach the server away from home.
    enum ExternalMode: String, Codable {
        /// SSH tunnel through a gateway, a key per device; no NAS port open to the internet.
        case ssh
        /// HTTPS through a reverse proxy (e.g. Nginx Proxy Manager); QTS password login.
        case https
        /// The router forwards a port to fsdrived itself; its own TLS key, which devices
        /// pinned at home, and QTS password login.
        case direct
    }

    var externalEnabled = false
    var externalMode: ExternalMode = .ssh
    /// Gateway address and port as seen from the internet.
    var gatewayHost = ""
    var gatewayPort = 22
    var gatewayUser = "fsdrive"
    /// Filled in by the gateway when it registers: its host key and LAN address.
    var gatewayHostKey = ""
    var gatewayAddress = ""
    /// Secret the gateway uses to fetch the device keys.
    var gatewayToken = ""
    /// HTTPS mode: the proxy's public address and the proxies whose X-Forwarded-For
    /// is believed (so the login guard blocks the real client, not the proxy).
    var publicURL = ""
    var trustedProxies: [String] = []
    /// Direct mode: the router's internet address (IP or name) and the port it forwards to the NAS.
    var directHost = ""
    var directPort = 8740

    /// Limits the admin set for some users; a user without an entry has none.
    var userLimits: [String: UserLimits] = [:]

    /// The SSH gateway is set up and devices can get keys.
    var externalReady: Bool { externalEnabled && externalMode == .ssh && !gatewayHost.isEmpty && !gatewayHostKey.isEmpty }
    /// The address clients use from the internet: through the reverse proxy or the forwarded port.
    var activePublicURL: String? {
        guard externalEnabled else { return nil }
        switch externalMode {
        case .https: return publicURL.isEmpty ? nil : publicURL
        case .direct: return directHost.isEmpty ? nil : "https://\(directHost.contains(":") ? "[\(directHost)]" : directHost):\(directPort)"
        case .ssh: return nil
        }
    }

    init() {}

    /// Missing fields keep their defaults, so the settings page may send only what it shows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storageMode = try c.decodeIfPresent(StorageMode.self, forKey: .storageMode) ?? .home
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath) ?? "/share/FSDrive"
        folderNaming = try c.decodeIfPresent(FolderNaming.self, forKey: .folderNaming) ?? .name
        allowedUsers = try c.decodeIfPresent([String].self, forKey: .allowedUsers) ?? []
        externalEnabled = try c.decodeIfPresent(Bool.self, forKey: .externalEnabled) ?? false
        externalMode = try c.decodeIfPresent(ExternalMode.self, forKey: .externalMode) ?? .ssh
        publicURL = try c.decodeIfPresent(String.self, forKey: .publicURL) ?? ""
        trustedProxies = try c.decodeIfPresent([String].self, forKey: .trustedProxies) ?? []
        directHost = try c.decodeIfPresent(String.self, forKey: .directHost) ?? ""
        directPort = try c.decodeIfPresent(Int.self, forKey: .directPort) ?? 8740
        gatewayHost = try c.decodeIfPresent(String.self, forKey: .gatewayHost) ?? ""
        gatewayPort = try c.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? 22
        gatewayUser = try c.decodeIfPresent(String.self, forKey: .gatewayUser) ?? "fsdrive"
        gatewayHostKey = try c.decodeIfPresent(String.self, forKey: .gatewayHostKey) ?? ""
        gatewayAddress = try c.decodeIfPresent(String.self, forKey: .gatewayAddress) ?? ""
        gatewayToken = try c.decodeIfPresent(String.self, forKey: .gatewayToken) ?? ""
        userLimits = try c.decodeIfPresent([String: UserLimits].self, forKey: .userLimits) ?? [:]
    }
}

/// An account from the system user database (QTS keeps users in /etc/passwd).
struct SystemUser: Codable {
    var name: String
    var uid: UInt32
    var gid: UInt32
    var home: String

    /// Login accounts: admin and regular users. System and guest accounts are left out.
    static func all() -> [SystemUser] {
        let path = ProcessInfo.processInfo.environment["FSDRIVE_PASSWD_FILE"] ?? "/etc/passwd"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ":", omittingEmptySubsequences: false)
            guard f.count >= 6, let uid = UInt32(f[2]), let gid = UInt32(f[3]) else { return nil }
            guard uid == 0 || (500..<65534).contains(uid) else { return nil }
            return SystemUser(name: String(f[0]), uid: uid, gid: gid, home: String(f[5]))
        }
    }

    static func named(_ name: String) -> SystemUser? { all().first { $0.name == name } }
}

/// Who a request comes from.
enum Principal {
    /// The server token from config.json: QTS settings page and maintenance tools.
    case admin
    case user(String)
}

struct UserStatus: Codable {
    var name: String
    var uid: UInt32
    var allowed: Bool
    var folder: String?
    var libraryId: Int64?
    /// "", "ready", or a problem the admin has to look at.
    var status: String
    var devices: Int
    var lastSeen: Int64?
    /// Each signed-in device, so a single one can be switched off.
    var deviceList: [DeviceInfo]
    /// Bytes the user's files take (counted against the quota).
    var usedBytes: Int64
    var limits: UserLimits?
}

/// What one user may do; each limit is off when nil.
struct UserLimits: Codable, Equatable {
    /// A device that has not connected for this many days must sign in again.
    var deviceIdleDays: Int?
    /// Largest single file, in GB.
    var maxFileSizeGB: Int?
    /// Space the user's files may take, in GB.
    var quotaGB: Int?

    var isEmpty: Bool { deviceIdleDays == nil && maxFileSizeGB == nil && quotaGB == nil }

    func validated() throws -> UserLimits {
        if let d = deviceIdleDays, !(1...3650).contains(d) { throw HTTPError(.badRequest, message: "Днів без зв'язку: від 1 до 3650") }
        if let f = maxFileSizeGB, f < 1 { throw HTTPError(.badRequest, message: "Найбільший файл: щонайменше 1 ГБ") }
        if let q = quotaGB, q < 1 { throw HTTPError(.badRequest, message: "Квота: щонайменше 1 ГБ") }
        return self
    }
}

struct DeviceInfo: Codable {
    var id: Int64
    var name: String
    var createdAt: Int64
    var lastSeen: Int64?
}

extension Store {
    // MARK: Settings

    func settings() throws -> FSDriveSettings {
        guard let json = try db.first("SELECT v FROM setting WHERE k = 'settings'", [], { $0.text(0) }),
              let s = try? JSONDecoder().decode(FSDriveSettings.self, from: Data(json.utf8)) else { return FSDriveSettings() }
        return s
    }

    func saveSettings(_ incoming: FSDriveSettings) throws {
        var s = incoming
        let old = try settings()
        // What the gateway reported and its secret are not edited on the page.
        s.gatewayHostKey = s.gatewayHostKey.isEmpty ? old.gatewayHostKey : s.gatewayHostKey
        s.gatewayAddress = s.gatewayAddress.isEmpty ? old.gatewayAddress : s.gatewayAddress
        s.gatewayToken = s.gatewayToken.isEmpty ? old.gatewayToken : s.gatewayToken
        s.publicURL = s.publicURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.externalEnabled && s.externalMode == .https {
            guard let u = URL(string: s.publicURL), u.scheme == "https", u.host != nil else {
                throw HTTPError(.badRequest, message: "Зовнішня адреса має бути https://…: паролі не можна передавати інтернетом без шифрування")
            }
        }
        if s.externalEnabled && s.externalMode == .direct {
            s.directHost = s.directHost.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            // An IPv6 literal has colons; a name or IPv4 address must come without scheme or port.
            let ipv6 = s.directHost.contains(":") && s.directHost.allSatisfy { $0.isHexDigit || $0 == ":" }
            guard !s.directHost.isEmpty, ipv6 || !s.directHost.contains(where: { " /:@".contains($0) }) else {
                throw HTTPError(.badRequest, message: "Вкажіть зовнішню адресу роутера (IP або ім'я, без https:// і порту)")
            }
            guard (1...65535).contains(s.directPort) else { throw HTTPError(.badRequest, message: "Неправильний зовнішній порт") }
        }
        if s.externalEnabled && s.externalMode == .ssh {
            s.gatewayHost = s.gatewayHost.trimmingCharacters(in: .whitespaces)
            guard !s.gatewayHost.isEmpty, !s.gatewayHost.contains(where: { " /:@".contains($0) }) else {
                throw HTTPError(.badRequest, message: "Вкажіть зовнішню адресу шлюзу (IP або ім'я, без порту)")
            }
            guard (1...65535).contains(s.gatewayPort) else { throw HTTPError(.badRequest, message: "Неправильний порт шлюзу") }
            if s.gatewayToken.isEmpty { s.gatewayToken = Store.randomSecret() }
        }
        // Limits are edited one user at a time (setLimits); a full save keeps them.
        s.userLimits = old.userLimits
        if s.storageMode == .folder {
            guard s.folderPath.hasPrefix("/"), FileIO.lstat(s.folderPath)?.kind == .dir else {
                throw HTTPError(.badRequest, message: "Тека \(s.folderPath) не існує")
            }
        }
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO setting(k, v) VALUES('settings', ?)", [.text(json)])
    }

    func isAllowed(_ user: String) throws -> Bool { try settings().allowedUsers.contains(user) }

    nonisolated static func randomSecret() -> String {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }).hex
    }

    /// The gateway reports its host key (clients pin it) and its LAN address (key
    /// requests coming from it are from outside the home and refused).
    func registerGateway(hostKey: String, address: String) throws {
        var s = try settings()
        s.gatewayHostKey = hostKey
        s.gatewayAddress = address
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO setting(k, v) VALUES('settings', ?)", [.text(json)])
    }

    // MARK: Personal libraries

    /// Folder for the user's files and the system folder for its uploads, versions and
    /// trash. That goes into the server's own data folder, out of users' reach, whenever
    /// it is on the same volume (moving uploads in and hard-linking versions need that);
    /// otherwise beside the library.
    func locations(for user: SystemUser, _ s: FSDriveSettings) throws -> (dir: String, sysDir: String) {
        let dir: String, beside: String
        switch s.storageMode {
        case .home:
            guard FileIO.lstat(user.home)?.kind == .dir else {
                throw HTTPError(.conflict, message: "Немає домашньої теки \(user.home): увімкніть домашні теки користувачів у QTS")
            }
            (dir, beside) = (user.home + "/FSDrive", user.home + "/.fsdrive-system")
        case .folder:
            let key = s.folderNaming == .uid ? String(user.uid) : user.name
            (dir, beside) = (s.folderPath + "/" + key, s.folderPath + "/.fsdrive-system/" + key)
        }
        if let a = FileIO.statFollowing((dir as NSString).deletingLastPathComponent), let b = FileIO.statFollowing(systemDir),
           a.device == b.device {
            return (dir, systemDir + "/libs/" + user.name)
        }
        return (dir, beside)
    }

    /// Before 0.4 the product was called Rimfile: a home library lived in <home>/Rimfile with
    /// its system folder in <home>/.rimfile-system (or <folder>/.rimfile-system/<user>).
    /// They take the new names in place, so the library and its devices' sync state stay.
    func renameLegacyFolders() throws {
        var libs: [(id: Int64, dir: String, sysDir: String?)] = []
        try db.query("SELECT id, dir, sys_dir FROM library WHERE active = 1 AND owner IS NOT NULL") {
            libs.append(($0.int(0), $0.text(1), $0.optText(2)))
        }
        let home = try settings().storageMode == .home
        for lib in libs {
            let dir = lib.dir as NSString
            if home, dir.lastPathComponent == "Rimfile" {
                let parentPath = dir.deletingLastPathComponent
                do {
                    let parent = try Dir.open(parentPath)
                    if parent.stat("Rimfile")?.kind == .dir, parent.stat("FSDrive") == nil {
                        try parent.rename("Rimfile", to: parent, as: "FSDrive")
                        try db.run("UPDATE library SET dir = ? WHERE id = ?", [.text(parentPath + "/FSDrive"), .int(lib.id)])
                        logLine("library folder \(lib.dir) renamed to \(parentPath)/FSDrive")
                    } else {
                        logLine("\(lib.dir) keeps its name: it is gone or FSDrive is already beside it")
                    }
                } catch {
                    logLine("\(lib.dir) keeps its name: \(error)")
                }
            }
            if let sys = lib.sysDir, let r = sys.range(of: "/.rimfile-system") {
                let newSys = sys.replacingCharacters(in: r, with: "/.fsdrive-system")
                try FileIO.mkdirs((newSys as NSString).deletingLastPathComponent)
                try relocateSystemFolder(from: sys, to: newSys)
                // Shared-folder mode leaves the old parent empty once every user has moved.
                let old = String(sys[..<r.upperBound])
                if old != sys { rmdir(old) }
            }
        }
    }

    /// The data folder was moved here from `oldRoot` (the QNAP package changed its name):
    /// paths the database keeps inside it follow. `oldRoot` as it was spelled in them.
    func relocateRoot(from oldRoot: String) throws {
        try db.transaction {
            for (table, column) in [("library", "dir"), ("library", "sys_dir"), ("upload", "data_path")] {
                try db.run("UPDATE \(table) SET \(column) = ? || substr(\(column), length(?) + 1) WHERE substr(\(column), 1, length(?) + 1) = ? || '/'",
                           [.text(root), .text(oldRoot), .text(oldRoot), .text(oldRoot)])
            }
        }
    }

    /// Makes sure the user has a personal library at the place the settings point to.
    /// An existing folder is adopted as is (the caller scans it); a new one is created
    /// owned by the user. Returns the library, or nil if it already was in place.
    @discardableResult
    func provision(_ name: String, rebind: Bool = false) throws -> Library? {
        guard let user = SystemUser.named(name) else { throw HTTPError(.notFound, message: "Користувача \(name) немає в QTS") }
        let s = try settings()
        if let known = try db.first("SELECT uid FROM account WHERE name = ?", [.text(name)], { UInt32($0.int(0)) }),
           known != user.uid, !rebind, s.storageMode == .home || s.folderNaming == .name {
            // Same name, different account: the old folder may hold someone else's files.
            try db.run("UPDATE account SET status = ? WHERE name = ?", [.text("uid змінився (\(known) → \(user.uid))"), .text(name)])
            throw HTTPError(.conflict, message: "Обліковий запис \(name) створено заново; адміністратор має підтвердити прив'язку теки")
        }
        let (dir, sysDir) = try locations(for: user, s)

        if let existing = try db.first(Store.libraryColumns + " WHERE l.owner = ? AND l.dir = ? AND l.active = 1",
                                       [.text(name), .text(dir)], libraryRecord) {
            if existing.sysDir != sysDir {
                try FileIO.mkdirs((sysDir as NSString).deletingLastPathComponent)
                try relocateSystemFolder(from: existing.sysDir, to: sysDir)
            }
            try db.run("INSERT OR REPLACE INTO account(name, uid, lib_id, status) VALUES(?, ?, ?, 'ready')",
                       [.text(name), .int(Int64(user.uid)), .int(existing.id)])
            return nil
        }

        // Both are opened without following a link in their place, so a user who put one
        // there cannot get a folder elsewhere created or handed over to them.
        let libDir: Dir, sys: Dir
        do {
            libDir = try Dir.openLibrary(dir, owner: user.uid, create: true) { $0.setOwner(uid: user.uid, gid: 0, mode: 0o770) }
            try FileIO.mkdirs((sysDir as NSString).deletingLastPathComponent)
            sys = try Dir.openSystem(sysDir, create: true)
        } catch let e as FileIOError where e.code == ELOOP || e.code == ENOTDIR {
            throw HTTPError(.conflict, message: "\(e.path) є посиланням або файлом, а не текою")
        } catch let e as FileIOError where e.code == EPERM {
            throw HTTPError(.conflict, message: "\(e.path): тека належить не тому користувачу; перевірте, хто її створив")
        }
        sys.setOwner(uid: 0, gid: 0, mode: 0o750)
        _ = try sys.sub("uploads", create: true)
        guard let a = libDir.info, let b = sys.info, a.device == b.device else {
            throw HTTPError(.conflict, message: "\(dir) і \(sysDir) мають бути на одному томі")
        }

        return try db.transaction {
            // One active personal library per user; earlier locations stay for history.
            try db.run("UPDATE library SET active = 0, name = name || ' @' || id WHERE owner = ? AND active = 1", [.text(name)])
            try db.run("UPDATE library SET name = name || ' @' || id WHERE name = ? AND active = 1", [.text(name)])
            try db.run("INSERT INTO library(name, dir, created_at, sys_dir, owner, active) VALUES(?, ?, ?, ?, ?, 1)",
                       [.text(name), .text(dir), .int(now), .text(sysDir), .text(name)])
            let id = db.lastInsertRowID
            try db.run("INSERT OR REPLACE INTO account(name, uid, lib_id, status) VALUES(?, ?, ?, 'ready')",
                       [.text(name), .int(Int64(user.uid)), .int(id)])
            return try library(id)
        }
    }

    /// Shows why a user's library could not be set up, on the settings page.
    func recordProblem(_ name: String, _ message: String) throws {
        let uid = SystemUser.named(name).map { Int64($0.uid) } ?? -1
        try db.run("INSERT OR IGNORE INTO account(name, uid) VALUES(?, ?)", [.text(name), .int(uid)])
        try db.run("UPDATE account SET status = ? WHERE name = ?", [.text(message), .text(name)])
    }

    func userStatuses() throws -> [UserStatus] {
        let s = try settings()
        var result = [UserStatus]()
        for u in SystemUser.all() {
            let account = try db.first("SELECT lib_id, status FROM account WHERE name = ?", [.text(u.name)]) { ($0.optInt(0), $0.text(1)) }
            var list = [DeviceInfo]()
            try db.query("SELECT id, name, created_at, last_seen FROM device WHERE user = ? ORDER BY COALESCE(last_seen, created_at) DESC",
                         [.text(u.name)]) { list.append(DeviceInfo(id: $0.int(0), name: $0.text(1), createdAt: $0.int(2), lastSeen: $0.optInt(3))) }
            let folder = try? locations(for: u, s).dir
            result.append(UserStatus(name: u.name, uid: u.uid, allowed: s.allowedUsers.contains(u.name), folder: folder,
                                     libraryId: account?.0, status: account?.1 ?? "", devices: list.count,
                                     lastSeen: list.compactMap(\.lastSeen).max(), deviceList: list, usedBytes: try usedBytes(owner: u.name),
                                     limits: s.userLimits[u.name]))
        }
        return result
    }

    // MARK: Device tokens

    /// A new random token for one device; only its hash is stored.
    func issueToken(user: String, device: String) throws -> (token: String, deviceId: Int64) {
        let token = Store.randomSecret()
        try db.run("INSERT INTO device(user, name, token_hash, created_at) VALUES(?, ?, ?, ?)",
                   [.text(user), .text(device), .blob(Hashing.sha256(Data(token.utf8))), .int(now)])
        return (token, db.lastInsertRowID)
    }

    /// The device a token belongs to. A device idle for longer than the admin allows is
    /// removed (its gateway key goes with it) and has to sign in again.
    func userForToken(_ token: String) throws -> (user: String, deviceId: Int64)? {
        let hash = Hashing.sha256(Data(token.utf8))
        guard let found = try db.first("SELECT user, id, COALESCE(last_seen, created_at), last_seen FROM device WHERE token_hash = ?", [.blob(hash)], {
            ($0.text(0), $0.int(1), $0.int(2), $0.optInt(3))
        }) else { return nil }
        if let days = try settings().userLimits[found.0]?.deviceIdleDays, now - found.2 > Int64(days) * 86400 {
            try db.run("DELETE FROM device WHERE id = ?", [.int(found.1)])
            logLine("device \(found.1) of \(found.0) expired after inactivity")
            throw HTTPError(.unauthorized, message: "Пристрій давно не з'єднувався з FSDrive; увійдіть знову")
        }
        // Clients poll every few seconds; a write per request would keep the NAS disks awake.
        if found.3.map({ now - $0 >= 300 }) ?? true {
            try db.run("UPDATE device SET last_seen = ? WHERE id = ?", [.int(now), .int(found.1)])
        }
        return (found.0, found.1)
    }

    /// Removes devices idle for longer than allowed, so their keys leave the gateway even
    /// if they never come back.
    func pruneIdleDevices() throws {
        var gone = [(Int64, String)]()
        for (user, limits) in try settings().userLimits {
            guard let days = limits.deviceIdleDays else { continue }
            try db.query("SELECT id, user FROM device WHERE user = ? AND COALESCE(last_seen, created_at) < ?",
                         [.text(user), .int(now - Int64(days) * 86400)]) { gone.append(($0.int(0), $0.text(1))) }
        }
        for (id, user) in gone {
            try db.run("DELETE FROM device WHERE id = ?", [.int(id)])
            logLine("device \(id) of \(user) expired after inactivity")
        }
    }

    /// Sets one user's limits; empty limits remove the entry.
    func setLimits(_ limits: UserLimits, for user: String) throws {
        var s = try settings()
        s.userLimits[user] = limits.isEmpty ? nil : try limits.validated()
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO setting(k, v) VALUES('settings', ?)", [.text(json)])
    }

    /// Signs out one device (`user`: only if it is theirs). Returns whether it existed.
    @discardableResult
    func revokeDevice(id: Int64, user: String? = nil) throws -> Bool {
        let owner = try db.first("SELECT user FROM device WHERE id = ?", [.int(id)]) { $0.text(0) }
        guard let owner, user == nil || owner == user else { return false }
        try db.run("DELETE FROM device WHERE id = ?", [.int(id)])
        logLine("device \(id) of \(owner) signed out")
        return true
    }

    /// Makes a new SSH key for a device, replacing any earlier one. Only the public
    /// half is kept; the private half goes to the device once.
    func issueSSHKey(deviceId: Int64, user: String) throws -> SSHKeys.Pair {
        let pair = SSHKeys.generate(comment: "fsdrive-\(user)-\(deviceId)")
        try db.run("UPDATE device SET ssh_key = ? WHERE id = ?", [.text(pair.publicKey), .int(deviceId)])
        return pair
    }

    /// Public keys of devices whose users are still allowed, for the gateway.
    func gatewayKeys() throws -> [String] {
        let allowed = Set(try settings().allowedUsers)
        var keys = [String]()
        try db.query("SELECT user, ssh_key FROM device WHERE ssh_key IS NOT NULL") { r in
            if allowed.contains(r.text(0)) { keys.append(r.text(1)) }
        }
        return keys
    }

    func revokeDevices(user: String) throws {
        try db.run("DELETE FROM device WHERE user = ?", [.text(user)])
    }
}

/// Checks a QTS user name and password with QTS itself (its authLogin.cgi), so FSDrive
/// never stores passwords and follows QTS account changes.
enum QTSAuth {
    /// FSDRIVE_AUTH_CGI lets tests stand in a script with the same interface.
    static let cgi = ProcessInfo.processInfo.environment["FSDRIVE_AUTH_CGI"] ?? "/home/httpd/cgi-bin/authLogin.cgi"

    enum Result { case ok, wrongPassword, twoStep, unavailable }

    static func verify(user: String, password: String) -> Result {
        guard FileManager.default.isExecutableFile(atPath: cgi) else { return .unavailable }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pwd = Data(password.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let name = user.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cgi)
        // The query goes in the environment, not argv, so other users cannot see it.
        process.environment = ["QUERY_STRING": "user=\(name)&pwd=\(pwd)&serviceKey=1", "REQUEST_METHOD": "GET", "REMOTE_ADDR": "127.0.0.1"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let xml = String(decoding: data, as: UTF8.self)
        if xml.contains("<authPassed><![CDATA[1]]></authPassed>") { return .ok }
        if xml.contains("need_2sv") || xml.contains("<lost_phone>") { return .twoStep }
        return .wrongPassword
    }
}
