import Foundation
import FSDriveCore
import Security

/// Secrets of the signed-in account in the login keychain: the access token and this
/// Mac's SSH key. Each item trusts exactly two programs, the menu bar app and the Finder
/// extension, so both read it without a prompt and other apps have to ask the user.
///
/// The data protection keychain would be tighter, but sharing it between the two needs
/// a provisioning profile, and a personal team's profile expires every week.
enum Keychain {
    enum Item: String {
        case token
        case sshKey = "ssh-key"
    }

    private static let service = "com.romulas.fsdrive"

    static func get(_ item: Item) -> String? {
        var query = base(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { logLine("keychain read \(item.rawValue): \(status)") }
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for item: Item) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = base(item)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "FSDrive (\(item.rawValue))"
        if let access = trustedAccess(item) { add[kSecAttrAccess as String] = access }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func remove(_ item: Item) {
        SecItemDelete(base(item) as CFDictionary)
    }

    private static func base(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    /// Access list naming the app and its Finder extension, whichever of the two
    /// creates the item.
    private static func trustedAccess(_ item: Item) -> SecAccess? {
        var app = Bundle.main.bundleURL
        if app.pathExtension == "appex" { app = app.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
        let paths = [app.path, app.appendingPathComponent("Contents/PlugIns/FSDriveFileProvider.appex").path]
        var trusted: [SecTrustedApplication] = []
        for path in paths {
            var t: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &t) == errSecSuccess, let t { trusted.append(t) }
        }
        guard trusted.count == paths.count else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("FSDrive (\(item.rawValue))" as CFString, trusted as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "\(status)")
    }
}
