import Foundation

/// Ed25519 key pairs in the formats OpenSSH uses: the private key as an
/// "OPENSSH PRIVATE KEY" file and the public key as an authorized_keys line.
public enum SSHKeys {
    public struct Pair: Sendable {
        /// Contents of an id_ed25519 file (unencrypted; the file must be mode 0600).
        public var privateKey: String
        /// "ssh-ed25519 AAAA... comment"
        public var publicKey: String
    }

    public static func generate(comment: String) -> Pair {
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation               // 32 bytes
        let pub = key.publicKey.rawRepresentation       // 32 bytes
        let publicBlob = string("ssh-ed25519") + string(pub)

        var checkBytes = [UInt8](repeating: 0, count: 4)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<4 { checkBytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        var secret = Data(checkBytes) + Data(checkBytes)
        secret += string("ssh-ed25519") + string(pub) + string(seed + pub) + string(Data(comment.utf8))
        var pad: UInt8 = 1
        while secret.count % 8 != 0 {
            secret.append(pad)
            pad += 1
        }

        var body = Data("openssh-key-v1".utf8) + Data([0])
        body += string("none") + string("none") + string(Data()) + uint32(1)
        body += string(publicBlob) + string(secret)

        let b64 = body.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 70).map { i -> String in
            let start = b64.index(b64.startIndex, offsetBy: i)
            return String(b64[start..<(b64.index(start, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
        return Pair(privateKey: privateKey, publicKey: "ssh-ed25519 \(publicBlob.base64EncodedString()) \(comment)")
    }

    private static func uint32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }

    private static func string(_ s: String) -> Data { string(Data(s.utf8)) }

    private static func string(_ d: Data) -> Data { uint32(UInt32(d.count)) + d }
}
