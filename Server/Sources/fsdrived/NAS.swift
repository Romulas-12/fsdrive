import Foundation

/// The NAS system fsdrived runs on. It decides how passwords are checked, which system
/// accounts are users, and which group gets access to users' files. Anything that is
/// not a Synology (QNAP, a Mac or Linux box in tests) behaves like QNAP.
enum NAS {
    case qnap
    case synology

    /// FSDRIVE_NAS (qnap or synology) lets tests pick one.
    static let current: NAS = {
        switch ProcessInfo.processInfo.environment["FSDRIVE_NAS"] {
        case "synology": return .synology
        case "qnap": return .qnap
        default: return FileManager.default.fileExists(atPath: "/etc.defaults/synoinfo.conf") ? .synology : .qnap
        }
    }()

    /// Name of the NAS operating system, for messages to the user.
    var system: String { self == .synology ? "DSM" : "QTS" }

    /// Group that may manage files FSDrive writes for users: administrators. On QNAP
    /// that is gid 0; on DSM, "administrators" is gid 101 and gid 0 is root alone.
    var adminGid: UInt32 { self == .synology ? 101 : 0 }

    /// Suggested shared folder for the "separate folder" storage mode.
    var defaultFolder: String { self == .synology ? "/volume1/FSDrive" : "/share/FSDrive" }

    /// Whether a line of /etc/passwd is a person's login account. QTS: admin (uid 0) and
    /// users from 500 up. DSM: users from 1024 up, without guest; packages get accounts
    /// with home folders in /var/packages.
    func isLoginAccount(name: String, uid: UInt32, home: String) -> Bool {
        switch self {
        case .qnap: return uid == 0 || (500..<65534).contains(uid)
        case .synology: return uid >= 1024 && uid < 65534 && name != "guest" && !home.hasPrefix("/var/packages/")
        }
    }

    enum AuthResult { case ok, wrongPassword, twoStep, refused(String), unavailable }

    /// Checks a user name and password with the NAS itself, so FSDrive never stores
    /// passwords and follows account changes made there.
    func verify(user: String, password: String) -> AuthResult {
        switch self {
        case .qnap: return QTSAuth.verify(user: user, password: password)
        case .synology: return DSMAuth.verify(user: user, password: password)
        }
    }
}

/// Form encoding for a value in a query string or form body.
func formEncoded(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

/// Checks a QTS user name and password with QTS itself (its authLogin.cgi).
enum QTSAuth {
    /// FSDRIVE_AUTH_CGI lets tests stand in a script with the same interface.
    static let cgi = ProcessInfo.processInfo.environment["FSDRIVE_AUTH_CGI"] ?? "/home/httpd/cgi-bin/authLogin.cgi"

    static func verify(user: String, password: String) -> NAS.AuthResult {
        guard FileManager.default.isExecutableFile(atPath: cgi) else { return .unavailable }
        let pwd = formEncoded(Data(password.utf8).base64EncodedString())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cgi)
        // The query goes in the environment, not argv, so other users cannot see it.
        process.environment = ["QUERY_STRING": "user=\(formEncoded(user))&pwd=\(pwd)&serviceKey=1", "REQUEST_METHOD": "GET", "REMOTE_ADDR": "127.0.0.1"]
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

/// Checks a DSM user name and password with DSM's own sign-in API on this NAS, then
/// signs the session out again. DSM applies its own rules there: disabled accounts,
/// expired passwords, 2-step verification.
enum DSMAuth {
    /// The DSM web API on this NAS; the service script sets it from DSM's port.
    static let url = ProcessInfo.processInfo.environment["FSDRIVE_DSM_URL"] ?? "http://127.0.0.1:5000/webapi/entry.cgi"
    static let curl = "/usr/bin/curl"

    static func verify(user: String, password: String) -> NAS.AuthResult {
        let login = "api=SYNO.API.Auth&version=6&method=login&session=FSDrive&format=sid&account=\(formEncoded(user))&passwd=\(formEncoded(password))"
        guard let reply = post(login) else { return .unavailable }
        if reply["success"] as? Bool == true {
            if let sid = (reply["data"] as? [String: Any])?["sid"] as? String {
                _ = post("api=SYNO.API.Auth&version=6&method=logout&session=FSDrive&_sid=\(formEncoded(sid))")
            }
            return .ok
        }
        // Error codes of SYNO.API.Auth.
        switch (reply["error"] as? [String: Any])?["code"] as? Int {
        case 403, 404, 406: return .twoStep
        case 401: return .refused("Обліковий запис \(user) вимкнено в DSM")
        case 402: return .refused("DSM не дозволяє \(user) входити (Панель керування → Привілеї застосунків)")
        case 407: return .refused("DSM тимчасово заблокував вхід (автоблокування в Панелі керування → Безпека)")
        case 408, 409, 410: return .refused("Пароль \(user) застарів: змініть його в DSM")
        case 400: return .wrongPassword
        default: return .unavailable
        }
    }

    /// POSTs a form to DSM with curl. The body, password included, goes in through
    /// stdin, never on the command line, where other users would see it.
    private static func post(_ body: String) -> [String: Any]? {
        guard FileManager.default.isExecutableFile(atPath: curl) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: curl)
        // -k: DSM's own certificate, on this machine, if http redirects to https.
        process.arguments = ["-s", "-k", "-m", "15", "-L", "--post301", "--post302", "--post303", "--data-binary", "@-", url]
        let input = Pipe(), out = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(body.utf8))
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
