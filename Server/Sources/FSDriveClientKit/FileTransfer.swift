import Foundation
import FSDriveCore

public struct LocalFileChanged: Error {}

public struct UploadResult {
    public var change: ChangeDTO
    /// True when the server kept the upload under a conflict name (`change.path`).
    public var conflict: Bool
    public var sentBytes: Int64
}

/// Moves file content between this machine and one library: delta downloads that
/// reuse local chunks, and uploads that send only chunks the server lacks.
public struct FileTransfer {
    public let api: APIClient
    public let libId: Int64
    public let device: String
    /// Concurrent connections per file. Measured on Wi-Fi to a QNAP: one TCP stream
    /// tops out near 10 MB/s upstream while 16–32 streams reach 60–90 MB/s, so a
    /// single connection never fills the link (32 streams measured 90–96 MB/s). The server only streams to disk, so
    /// more connections add no work there.
    public var uploadStreams = 32
    /// Cap on chunk bytes held in memory by uploads in flight (each chunk is also
    /// copied by URLSession while it is sent).
    public var uploadBudget = 48 << 20
    public var downloadStreams = 8

    public init(api: APIClient, libId: Int64, device: String) {
        self.api = api
        self.libId = libId
        self.device = device
    }

    // MARK: Download

    /// Builds `version` in `temp`: chunks found in `reuse` files are copied locally,
    /// the rest are fetched in batches. Returns bytes fetched over the network.
    public func download(versionId: Int64, manifest: Manifest, to temp: String, reuse: [(path: String, manifest: Manifest)] = [],
                         progress: ((Int64) -> Void)? = nil) async throws -> Int64 {
        let out = try FileIO.open(temp, O_RDWR | O_CREAT | O_TRUNC, mode: 0o644, noCache: true)
        defer { close(out) }
        guard ftruncate(out, off_t(manifest.size)) == 0 else { throw FileIOError(op: "ftruncate", path: temp, code: errno) }

        var localChunks = [Data: (path: String, offset: Int64)]()
        for source in reuse {
            for c in source.manifest.chunks { localChunks[c.hash] = (source.path, c.offset) }
        }
        let needed: [ChunkInfo] = try await runBlocking {
            var missing = [ChunkInfo]()
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: Chunker.maxSize, alignment: 16)
            defer { buf.deallocate() }
            var fds = [String: Int32]()
            defer { for fd in fds.values { close(fd) } }
            for c in manifest.chunks {
                if let src = localChunks[c.hash] {
                    let fd = try fds[src.path] ?? FileIO.open(src.path, O_RDONLY, noCache: true)
                    fds[src.path] = fd
                    let n = try FileIO.pread(fd, into: buf.baseAddress!, count: c.length, offset: src.offset, path: src.path)
                    if n == c.length, Hashing.sha256(UnsafeRawBufferPointer(rebasing: buf[0..<n])) == c.hash {
                        try FileIO.pwrite(out, buf.baseAddress!, count: n, offset: c.offset, path: temp)
                        continue
                    }
                }
                missing.append(c)
            }
            return missing
        }
        let report = ProgressSink(progress)
        report.add(manifest.size - needed.reduce(0) { $0 + Int64($1.length) })

        // Batches of up to 16 MiB fetched over several connections at once; each batch
        // writes to its own offsets, so they never overlap.
        var batches = [[ChunkInfo]]()
        var batchBytes = 0
        for c in needed {
            if batches.isEmpty || batchBytes >= 16 << 20 {
                batches.append([])
                batchBytes = 0
            }
            batches[batches.count - 1].append(c)
            batchBytes += c.length
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = batches.makeIterator()
            func next() -> Bool {
                guard let batch = pending.next() else { return false }
                group.addTask { try await fetch(batch, versionId: versionId, out: out, temp: temp, report: report) }
                return true
            }
            for _ in 0..<downloadStreams where next() {}
            while try await group.next() != nil { _ = next() }
        }
        FileIO.barrierSync(out)
        return needed.reduce(0) { $0 + Int64($1.length) }
    }

    private func fetch(_ chunks: [ChunkInfo], versionId: Int64, out: Int32, temp: String, report: ProgressSink) async throws {
        var ranges = [[Int64]]()
        for c in chunks {
            if let last = ranges.last, last[0] + last[1] == c.offset {
                ranges[ranges.count - 1][1] += Int64(c.length)
            } else {
                ranges.append([c.offset, Int64(c.length)])
            }
        }
        let writer = ChunkWriter(chunks: chunks, fd: out, path: temp)
        try await api.streamRanges(lib: libId, version: versionId, ranges: ranges) { data in
            try writer.consume(data)
            report.add(Int64(data.count))
        }
        try writer.finish()
    }

    // MARK: Upload

    /// Uploads `file` as `path`. `base` is the version this edit started from (nil for
    /// a new file); if the server has moved on, it keeps the upload as a conflict copy.
    public func upload(file: String, as path: String, base: Int64?, mtimeNs: Int64, manifest: Manifest,
                       progress: ((Int64) -> Void)? = nil) async throws -> UploadResult {
        let created = try await api.createUpload(lib: libId, CreateUploadRequest(
            path: path, baseVersionId: base, mtimeNs: mtimeNs, contentHash: manifest.contentHash.hex, chunks: manifest.dto, device: device))
        let report = ProgressSink(progress)
        report.add(manifest.size - sizeOf(created.missing, in: manifest))
        var missing = created.missing
        var sent: Int64 = 0
        for _ in 0..<3 {
            sent += try await sendChunks(missing, uploadId: created.uploadId, of: manifest, from: file, report: report)
            let r = try await api.commit(uploadId: created.uploadId)
            if r.status == "missing" {
                missing = r.missing ?? []
                continue
            }
            guard let change = r.change else { break }
            return UploadResult(change: change, conflict: r.conflict, sentBytes: sent)
        }
        throw APIError(status: 0, message: "upload of \(path) did not complete")
    }

    private func sizeOf(_ hashes: [String], in manifest: Manifest) -> Int64 {
        let wanted = Set(hashes)
        var seen = Set<String>()
        var total: Int64 = 0
        for c in manifest.chunks where wanted.contains(c.hash.hex) && seen.insert(c.hash.hex).inserted { total += Int64(c.length) }
        return total
    }

    private func sendChunks(_ hashes: [String], uploadId: String, of manifest: Manifest, from path: String,
                            report: ProgressSink) async throws -> Int64 {
        guard !hashes.isEmpty else { return 0 }
        var byHash = [String: ChunkInfo]()
        for c in manifest.chunks where byHash[c.hash.hex] == nil { byHash[c.hash.hex] = c }
        let fd = try FileIO.open(path, O_RDONLY, noCache: true)
        defer { close(fd) }
        let api = self.api
        var total: Int64 = 0
        let chunks = hashes.compactMap { byHash[$0] }
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var nextIndex = 0
            var running = 0
            var inFlight = 0
            // Start chunks until either limit is reached; one chunk always runs.
            func launch() {
                while nextIndex < chunks.count, running < uploadStreams,
                      running == 0 || inFlight + chunks[nextIndex].length <= uploadBudget {
                    let c = chunks[nextIndex]
                    nextIndex += 1
                    running += 1
                    inFlight += c.length
                    group.addTask {
                        var data = Data(count: c.length)
                        let n = try data.withUnsafeMutableBytes { try FileIO.pread(fd, into: $0.baseAddress!, count: c.length, offset: c.offset, path: path) }
                        guard n == c.length, Hashing.sha256(data) == c.hash else { throw LocalFileChanged() }
                        try await api.putChunk(uploadId: uploadId, hash: c.hash.hex, data: data)
                        return Int64(c.length)
                    }
                }
            }
            launch()
            while let sent = try await group.next() {
                running -= 1
                inFlight -= Int(sent)
                total += sent
                report.add(sent)
                launch()
            }
        }
        return total
    }
}

/// Forwards byte counts from concurrent transfers to one progress callback, one at a time.
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private let callback: ((Int64) -> Void)?

    init(_ callback: ((Int64) -> Void)?) { self.callback = callback }

    func add(_ bytes: Int64) {
        guard let callback else { return }
        lock.lock()
        defer { lock.unlock() }
        callback(bytes)
    }
}

/// Writes a stream of concatenated chunks to their offsets, verifying each hash.
final class ChunkWriter {
    let chunks: [ChunkInfo]
    let fd: Int32
    let path: String
    private var index = 0
    private var written = 0
    private var hasher = SHA256()

    init(chunks: [ChunkInfo], fd: Int32, path: String) {
        self.chunks = chunks
        self.fd = fd
        self.path = path
    }

    func consume(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var pos = 0
            while pos < raw.count {
                guard index < chunks.count else { throw APIError(status: 0, message: "server sent extra bytes") }
                let c = chunks[index]
                let n = min(c.length - written, raw.count - pos)
                let piece = UnsafeRawBufferPointer(rebasing: raw[pos..<pos + n])
                hasher.update(bufferPointer: piece)
                try FileIO.pwrite(fd, piece.baseAddress!, count: n, offset: c.offset + Int64(written), path: path)
                written += n
                pos += n
                if written == c.length {
                    guard Data(hasher.finalize()) == c.hash else {
                        throw APIError(status: 0, message: "chunk \(c.hash.hex.prefix(12)) failed verification")
                    }
                    hasher = SHA256()
                    index += 1
                    written = 0
                }
            }
        }
    }

    func finish() throws {
        guard index == chunks.count else { throw APIError(status: 0, message: "download ended early") }
    }
}
