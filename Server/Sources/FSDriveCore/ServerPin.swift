import Foundation

/// The server's identity as clients remember it: the SHA-256 of its public key
/// (SubjectPublicKeyInfo), written "sha256/<base64>". The same key keeps the same pin
/// when its certificate is renewed.
public enum ServerPin {
    public static func pin(spki: Data) -> String { "sha256/" + Hashing.sha256(spki).base64EncodedString() }

    /// SubjectPublicKeyInfo of a P-256 key from its raw point (04 || x || y), which is
    /// what Security.framework hands out for an EC key.
    public static func spki(p256Point point: Data) -> Data? {
        guard point.count == 65, point.first == 0x04 else { return nil }
        // SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING { point } }
        let header: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                               0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        return Data(header) + point
    }

    /// A short form for people to compare, e.g. "3F9A-0C21-7B44-E810": the first 8 bytes
    /// of the hash. Matching it by chance would take about 2^64 tries.
    public static func code(_ pin: String) -> String {
        guard let raw = Data(base64Encoded: String(pin.dropFirst("sha256/".count))), raw.count >= 8 else { return pin }
        let hex = raw.prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 16, by: 4).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 4)])
        }.joined(separator: "-")
    }
}
