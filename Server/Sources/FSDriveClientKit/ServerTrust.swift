import Foundation
import FSDriveCore
import Security

/// Decides which TLS certificates a client accepts. fsdrived makes its own certificate,
/// so no authority vouches for it: the client remembers the server's public key the
/// first time (trust on first use, as SSH does) and from then on accepts only that key,
/// whatever address, tunnel or name the server is reached by. A certificate the system
/// trusts (a reverse proxy with a public certificate) is accepted the usual way.
public final class ServerTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pinned: String?
    private var rejected: String?
    private let onLearn: (@Sendable (String) -> Void)?

    /// `pin`: the key remembered earlier, or nil to learn it from the first server
    /// that answers. `onLearn` is told once, so the caller can keep it.
    public init(pin: String?, onLearn: (@Sendable (String) -> Void)? = nil) {
        pinned = pin
        self.onLearn = onLearn
    }

    /// The pinned key ("sha256/…"), nil until learned.
    public var pin: String? { lock.withLock { pinned } }

    /// The key of a server that was refused because it differs from the pinned one.
    public var mismatch: String? { lock.withLock { rejected } }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let presented = Self.pin(of: trust)
        enum Verdict { case pinned, system, learned(String), refuse }
        let verdict: Verdict = lock.withLock {
            if let presented, presented == pinned { return .pinned }
            if SecTrustEvaluateWithError(trust, nil) { return .system }
            guard let presented else { return .refuse }
            if pinned == nil {
                pinned = presented
                return .learned(presented)
            }
            rejected = presented
            return .refuse
        }
        switch verdict {
        case .pinned:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .system:
            completionHandler(.performDefaultHandling, nil)
        case .learned(let pin):
            onLearn?(pin)
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .refuse:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// The pin of the leaf certificate's key; only P-256 keys (what fsdrived makes) have one.
    static func pin(of trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let key = SecCertificateCopyKey(leaf),
              let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              attrs[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attrs[kSecAttrKeySizeInBits] as? Int == 256,
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let spki = ServerPin.spki(p256Point: point) else { return nil }
        return ServerPin.pin(spki: spki)
    }
}

extension URL {
    /// fsdrived speaks only TLS: addresses saved as http:// by earlier versions are
    /// reached with https:// on the same port.
    var upgradedToTLS: URL {
        guard scheme == "http", var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        c.scheme = "https"
        return c.url ?? self
    }

    /// The internet address of a reverse proxy rather than fsdrived itself, which always
    /// has its own port (8740 by default) in the address.
    public var isProxyAddress: Bool { port == nil || port == 443 }

    /// An address inside the home network: a private or link-local IP, or a .local or
    /// single-label name. Anything else (a proxy, a port forwarded on the router) is the
    /// internet route.
    public var isHomeAddress: Bool {
        guard let host = host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() else { return false }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
                || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        return host.hasSuffix(".local") || !host.contains(".")
    }
}
