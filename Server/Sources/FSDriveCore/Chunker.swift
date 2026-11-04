import Foundation

public struct ChunkInfo: Hashable, Sendable {
    public var hash: Data
    public var offset: Int64
    public var length: Int

    public init(hash: Data, offset: Int64, length: Int) {
        self.hash = hash
        self.offset = offset
        self.length = length
    }
}

public struct Manifest: Equatable, Sendable {
    public var chunks: [ChunkInfo]
    public var size: Int64
    public var contentHash: Data

    public init(chunks: [ChunkInfo]) {
        self.chunks = chunks
        self.size = chunks.reduce(0) { $0 + Int64($1.length) }
        self.contentHash = Manifest.contentHash(of: chunks)
    }

    /// The file hash is SHA-256 over the concatenated chunk hashes, so the server can
    /// derive it from verified chunks without reading the file a second time.
    public static func contentHash(of chunks: [ChunkInfo]) -> Data {
        var concatenated = Data(capacity: chunks.count * 32)
        for c in chunks { concatenated.append(c.hash) }
        return Hashing.sha256(concatenated)
    }

    /// Compact form for the database: 32-byte hash + UInt32 length per chunk.
    public func encoded() -> Data {
        var out = Data(capacity: chunks.count * 36)
        for c in chunks {
            out.append(c.hash)
            var len = UInt32(c.length).littleEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        }
        return out
    }

    public static func decode(_ data: Data) -> Manifest {
        var chunks = [ChunkInfo]()
        chunks.reserveCapacity(data.count / 36)
        var offset: Int64 = 0
        data.withUnsafeBytes { raw in
            var i = 0
            while i + 36 <= raw.count {
                let hash = Data(raw[i..<i + 32])
                let len = Int(raw.loadUnaligned(fromByteOffset: i + 32, as: UInt32.self).littleEndian)
                chunks.append(ChunkInfo(hash: hash, offset: offset, length: len))
                offset += Int64(len)
                i += 36
            }
        }
        return Manifest(chunks: chunks)
    }
}

/// FastCDC content-defined chunking. Boundaries depend only on content, so an insert
/// in the middle of a file changes only the chunks around it.
///
/// The gear table and size parameters are part of the on-wire format: changing them
/// changes every chunk hash.
public enum Chunker {
    public static let minSize = 256 << 10
    public static let avgBits = 20  // 1 MiB
    public static let maxSize = 4 << 20

    static let maskS: UInt64 = ~UInt64(0) << UInt64(64 - (avgBits + 2))
    static let maskL: UInt64 = ~UInt64(0) << UInt64(64 - (avgBits - 2))

    static let gear: UnsafeMutablePointer<UInt64> = {
        let table = UnsafeMutablePointer<UInt64>.allocate(capacity: 256)
        var state: UInt64 = 0x5641_554C_5400_0001  // "RIMFILE" seed, splitmix64
        for i in 0..<256 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            table[i] = z ^ (z >> 31)
        }
        return table
    }()

    /// Length of the next chunk among the `n` bytes at `p`. When `n < maxSize` the
    /// caller must be at end of input.
    static func cut(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
        if n <= minSize { return n }
        let end = min(n, maxSize)
        let normal = min(end, 1 << avgBits)
        var h: UInt64 = 0
        var i = minSize
        while i < normal {
            h = (h << 1) &+ gear[Int(p[i])]
            if h & maskS == 0 { return i + 1 }
            i += 1
        }
        while i < end {
            h = (h << 1) &+ gear[Int(p[i])]
            if h & maskL == 0 { return i + 1 }
            i += 1
        }
        return end
    }

    public static func manifest(of data: Data) -> Manifest {
        var chunks = [ChunkInfo]()
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var pos = 0
            while pos < raw.count {
                let len = cut(base + pos, raw.count - pos)
                let hash = Hashing.sha256(UnsafeRawBufferPointer(rebasing: raw[pos..<pos + len]))
                chunks.append(ChunkInfo(hash: hash, offset: Int64(pos), length: len))
                pos += len
            }
        }
        return Manifest(chunks: chunks)
    }

    /// Chunks a file in one sequential pass with a fixed 8 MiB buffer and without
    /// filling the page cache.
    public static func manifest(ofFileAt path: String) throws -> Manifest {
        let fd = try FileIO.open(path, O_RDONLY, noCache: true)
        defer { close(fd) }
        return try manifest(of: fd, path: path)
    }

    /// The same for a file already open; `path` is for messages.
    public static func manifest(of fd: Int32, path: String) throws -> Manifest {
        let capacity = maxSize * 2
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buf.deallocate() }
        let base = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)

        var chunks = [ChunkInfo]()
        var filled = 0, pos = 0
        var fileOffset: Int64 = 0
        var eof = false
        while true {
            if !eof && filled - pos < maxSize {
                if pos > 0 {
                    memmove(base, base + pos, filled - pos)
                    filled -= pos
                    pos = 0
                }
                let n = try FileIO.read(fd, into: base + filled, count: capacity - filled, path: path)
                filled += n
                if filled < capacity { eof = true }
            }
            let avail = filled - pos
            if avail == 0 { break }
            if pos == 0 { FileIO.dropCache(fd, offset: 0, length: fileOffset) }
            let len = cut(base + pos, avail)
            let hash = Hashing.sha256(UnsafeRawBufferPointer(start: base + pos, count: len))
            chunks.append(ChunkInfo(hash: hash, offset: fileOffset, length: len))
            pos += len
            fileOffset += Int64(len)
        }
        return Manifest(chunks: chunks)
    }
}
