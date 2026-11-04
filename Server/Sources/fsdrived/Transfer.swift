import Foundation
import Hummingbird
import FSDriveCore

/// Caps concurrent heavy transfers. Waiting requests are not read from the socket,
/// so TCP flow control slows senders down instead of the server buffering data.
actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Keeps the Mac awake only while transfers are running.
actor Activity {
    private var count = 0
    private var token: NSObjectProtocol?

    func begin() {
        count += 1
        #if os(macOS)
        if count == 1 {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "fsdrived transfer")
        }
        #endif
    }

    func end() {
        count -= 1
        #if os(macOS)
        if count == 0, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
        #endif
    }
}

struct Transfers {
    let store: Store
    let limiter: Limiter
    let activity: Activity

    private func withTransfer<T>(_ body: () async throws -> T) async throws -> T {
        await limiter.acquire()
        await activity.begin()
        defer {
            Task {
                await activity.end()
                await limiter.release()
            }
        }
        return try await body()
    }

    /// Streams one chunk straight to its offset in the preallocated upload file,
    /// hashing as it goes.
    func receiveChunk(uploadId: String, hashHex: String, body: RequestBody) async throws {
        let session = try await store.session(uploadId)
        guard let hash = Data(hex: hashHex), let slot = session.layout[hash] else {
            throw HTTPError(.badRequest, message: "chunk \(hashHex) is not part of this upload")
        }
        if session.received.contains(hash) { return }
        let path = session.dataPath
        try await withTransfer {
            let fd = try session.openData(O_WRONLY, noCache: true)
            defer { close(fd) }
            var hasher = SHA256()
            var written = 0
            let base = slot.offsets[0]
            for try await buffer in body {
                let n = buffer.readableBytes
                guard written + n <= slot.length else { throw HTTPError(.badRequest, message: "chunk longer than declared") }
                try buffer.withUnsafeReadableBytes { raw in
                    hasher.update(bufferPointer: raw)
                    try FileIO.pwrite(fd, raw.baseAddress!, count: n, offset: base + Int64(written), path: path)
                }
                written += n
            }
            guard written == slot.length, Data(hasher.finalize()) == hash else {
                throw HTTPError(.badRequest, message: "chunk \(hashHex) failed verification")
            }
            if slot.offsets.count > 1 {
                try runBlockingCopy(fd: fd, session: session, from: base, to: Array(slot.offsets.dropFirst()), length: slot.length)
            }
        }
        try await store.markReceived(uploadId, hash: hash)
    }

    private func runBlockingCopy(fd: Int32, session: UploadSession, from: Int64, to offsets: [Int64], length: Int) throws {
        let path = session.dataPath
        let rfd = try session.openData(O_RDONLY)
        defer { close(rfd) }
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 16)
        defer { buf.deallocate() }
        _ = try FileIO.pread(rfd, into: buf.baseAddress!, count: length, offset: from, path: path)
        for o in offsets { try FileIO.pwrite(fd, buf.baseAddress!, count: length, offset: o, path: path) }
    }

    /// Fills chunks the client did not send from existing files (verified by hash),
    /// then moves the result into the library.
    func commit(uploadId: String) async throws -> CommitResponse {
        let session = try await store.session(uploadId)
        let needed = Set(session.layout.keys).subtracting(session.received)
        let sources = try await store.chunkSources(needed, lib: session.libId)
        let access = try await store.access(lib: session.libId)
        let missing = try await withTransfer {
            try await runBlocking(qos: .utility) {
                try Transfers.assemble(session: session, access: access, needed: needed, sources: sources)
            }
        }
        if !missing.isEmpty {
            return CommitResponse(status: "missing", missing: missing.map(\.hex))
        }
        return try await store.finalize(uploadId)
    }

    /// Chunks are read with the rights of the uploading user: bytes from a file they
    /// could not open themselves are not used.
    static func assemble(session: UploadSession, access: FileAccess?, needed: Set<Data>, sources: [Data: [ChunkSource]]) throws -> [Data] {
        let dataPath = session.dataPath
        let out = try session.openData(O_WRONLY, noCache: true)
        defer { close(out) }
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: Chunker.maxSize, alignment: 16)
        defer { buf.deallocate() }
        var fds = [FileRef: Int32]()
        defer { for fd in fds.values { close(fd) } }

        var missing = [Data]()
        for hash in needed {
            guard let slot = session.layout[hash] else { continue }
            var found = false
            for src in sources[hash] ?? [] where src.length == slot.length {
                let fd: Int32
                if let cached = fds[src.file] {
                    fd = cached
                } else {
                    guard let opened = try? src.file.open(as: access, noCache: true) else { continue }
                    fds[src.file] = opened
                    fd = opened
                }
                guard let n = try? FileIO.pread(fd, into: buf.baseAddress!, count: slot.length, offset: src.offset, path: src.file.path),
                      n == slot.length,
                      Hashing.sha256(UnsafeRawBufferPointer(rebasing: buf[0..<n])) == hash else { continue }
                for o in slot.offsets { try FileIO.pwrite(out, buf.baseAddress!, count: n, offset: o, path: dataPath) }
                found = true
                break
            }
            if !found { missing.append(hash) }
        }
        if missing.isEmpty { FileIO.barrierSync(out) }
        return missing
    }

    /// Streams byte ranges of a stored version, 1 MiB at a time.
    func ranges(lib: Int64, versionId: Int64, ranges: [[Int64]]?) async throws -> Response {
        guard let v = try await store.versionPath(versionId), v.libId == lib else {
            throw HTTPError(.notFound, message: "version \(versionId) is not available")
        }
        let size = v.manifest.size
        // Written so that no sum can overflow: Swift stops the whole server on overflow.
        var total: Int64 = 0
        let wanted: [(Int64, Int64)] = try (ranges ?? [[0, size]]).map { pair in
            guard pair.count == 2, pair[0] >= 0, pair[1] >= 0, pair[0] <= size, pair[1] <= size - pair[0] else {
                throw HTTPError(.badRequest, message: "range out of bounds")
            }
            let (sum, overflow) = total.addingReportingOverflow(pair[1])
            guard !overflow else { throw HTTPError(.badRequest, message: "ranges too large") }
            total = sum
            return (pair[0], pair[1])
        }
        let file = v.file, access = v.access
        let path = file.path
        // Fail with a status while there is still time to send one; the body reopens it.
        guard let probe = try? file.open(as: access) else { throw HTTPError(.notFound, message: "version \(versionId) is not available") }
        close(probe)
        let activity = self.activity
        let body = ResponseBody(contentLength: Int(total)) { writer in
            await activity.begin()
            let fd: Int32
            do { fd = try file.open(as: access, noCache: true) } catch {
                await activity.end()
                throw error
            }
            defer {
                close(fd)
                Task { await activity.end() }
            }
            let piece = 1 << 20
            var buffer = ByteBufferAllocator().buffer(capacity: piece)
            for (offset, length) in wanted {
                var off = offset
                var remaining = length
                while remaining > 0 {
                    let n = Int(min(remaining, Int64(piece)))
                    buffer.clear()
                    let read = try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: n) { ptr in
                        try FileIO.pread(fd, into: ptr.baseAddress!, count: n, offset: off, path: path)
                    }
                    guard read == n else { throw HTTPError(.internalServerError, message: "file shrank while reading") }
                    FileIO.dropCache(fd, offset: off, length: Int64(n))
                    try await writer.write(buffer)
                    off += Int64(n)
                    remaining -= Int64(n)
                }
            }
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: [.contentType: "application/octet-stream"], body: body)
    }
}
