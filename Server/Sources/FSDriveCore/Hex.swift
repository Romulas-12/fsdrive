import Foundation

public enum FSDriveVersion {
    public static let string = "0.4.2"
}

extension Data {
    public var hex: String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: count * 2)
        for (i, b) in enumerated() {
            out[i * 2] = digits[Int(b >> 4)]
            out[i * 2 + 1] = digits[Int(b & 0x0F)]
        }
        return String(decoding: out, as: UTF8.self)
    }

    public init?(hex: String) {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}

public enum Hashing {
    /// SHA-256 of a memory region (uses ARMv8 SHA instructions via CryptoKit).
    public static func sha256(_ buffer: UnsafeRawBufferPointer) -> Data {
        Data(SHA256.hash(data: buffer))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
