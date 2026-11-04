import Foundation

// File-scope wrappers: inside `enum FileIO` the bare names would resolve to its own
// static methods.
private func sysLstat(_ path: String, _ st: inout stat) -> Int32 { lstat(path, &st) }
private func sysStat(_ path: String, _ st: inout stat) -> Int32 { stat(path, &st) }
private func sysOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { open(path, flags, mode) }
private func sysRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int { read(fd, buf, n) }
private func sysPread(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int, _ off: off_t) -> Int { pread(fd, buf, n, off) }
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int { write(fd, buf, n) }
private func sysPwrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int, _ off: off_t) -> Int { pwrite(fd, buf, n, off) }
private func sysRename(_ a: String, _ b: String) -> Int32 { rename(a, b) }

#if os(Linux)
let utimeOmit = 0x3FFF_FFFE  // UTIME_OMIT; glibc's macro is not importable
#else
let utimeOmit = Int(UTIME_OMIT)
#endif

public struct FileIOError: Error, CustomStringConvertible {
    public let op: String
    public let path: String
    public let code: Int32

    public init(op: String, path: String, code: Int32) {
        self.op = op
        self.path = path
        self.code = code
    }

    public var description: String { "\(op) \(path): \(String(cString: strerror(code)))" }
}

public struct StatInfo: Equatable, Sendable {
    public enum Kind: Sendable { case file, dir, symlink, other }
    public var kind: Kind
    public var size: Int64
    public var mtimeNs: Int64
    public var inode: Int64
    public var device: Int64
}

extension StatInfo {
    init(_ st: stat) {
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .dir
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        #if os(Linux)
        let ts = st.st_mtim
        #else
        let ts = st.st_mtimespec
        #endif
        mtimeNs = Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
        size = Int64(st.st_size)
        inode = Int64(st.st_ino)
        device = Int64(st.st_dev)
    }
}

/// Thin POSIX helpers. Everything streams through fixed-size buffers so memory use
/// does not depend on file size (architecture §6.1).
public enum FileIO {
    public static let bufferSize = 1 << 20

    public static func lstat(_ path: String) -> StatInfo? {
        var st = stat()
        guard sysLstat(path, &st) == 0 else { return nil }
        return StatInfo(st)
    }

    /// Like `lstat`, but follows symlinks (for admin-chosen paths such as /share/<folder>).
    public static func statFollowing(_ path: String) -> StatInfo? {
        var st = stat()
        guard sysStat(path, &st) == 0 else { return nil }
        return StatInfo(st)
    }

    public static func open(_ path: String, _ flags: Int32, mode: mode_t = 0o644, noCache: Bool = false) throws -> Int32 {
        let fd = sysOpen(path, flags | O_CLOEXEC, mode)
        guard fd >= 0 else { throw FileIOError(op: "open", path: path, code: errno) }
        // Bulk transfers bypass the buffer cache so big syncs do not evict the user's
        // working set from RAM. Linux has no such flag; see `dropCache`.
        #if canImport(Darwin)
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        #endif
        return fd
    }

    /// Tells Linux it can drop already-read pages of a file streamed once (a no-op on
    /// macOS, where F_NOCACHE does this).
    public static func dropCache(_ fd: Int32, offset: Int64, length: Int64) {
        #if os(Linux)
        _ = posix_fadvise(fd, off_t(offset), off_t(length), Int32(POSIX_FADV_DONTNEED))
        #endif
    }

    /// Reads up to `count` bytes; returns fewer only at EOF.
    public static func read(_ fd: Int32, into buf: UnsafeMutableRawPointer, count: Int, path: String) throws -> Int {
        var done = 0
        while done < count {
            let n = sysRead(fd, buf + done, count - done)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw FileIOError(op: "read", path: path, code: errno)
            }
            done += n
        }
        return done
    }

    public static func pread(_ fd: Int32, into buf: UnsafeMutableRawPointer, count: Int, offset: Int64, path: String) throws -> Int {
        var done = 0
        while done < count {
            let n = sysPread(fd, buf + done, count - done, off_t(offset) + off_t(done))
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw FileIOError(op: "pread", path: path, code: errno)
            }
            done += n
        }
        return done
    }

    public static func write(_ fd: Int32, _ buf: UnsafeRawPointer, count: Int, path: String) throws {
        var done = 0
        while done < count {
            let n = sysWrite(fd, buf + done, count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileIOError(op: "write", path: path, code: errno)
            }
            done += n
        }
    }

    public static func pwrite(_ fd: Int32, _ buf: UnsafeRawPointer, count: Int, offset: Int64, path: String) throws {
        var done = 0
        while done < count {
            let n = sysPwrite(fd, buf + done, count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw FileIOError(op: "pwrite", path: path, code: errno)
            }
            done += n
        }
    }

    /// Orders the file's writes before later metadata operations (rename). On macOS
    /// this avoids F_FULLFSYNC, which flushes the whole drive cache.
    public static func barrierSync(_ fd: Int32) {
        #if canImport(Darwin)
        if fcntl(fd, F_BARRIERFSYNC) != 0 { _ = fsync(fd) }
        #else
        _ = fdatasync(fd)
        #endif
    }

    public static func setMtime(_ path: String, ns: Int64) {
        var times = [
            timespec(tv_sec: 0, tv_nsec: utimeOmit),
            timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000)),
        ]
        _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// Best effort: without root (e.g. tests on a Mac) ownership simply stays as is. By
    /// descriptor, so a symlink swapped in for the file cannot redirect it.
    public static func setOwner(fd: Int32, uid: UInt32, gid: UInt32, mode: UInt16) {
        _ = fchown(fd, uid_t(uid), gid_t(gid))
        _ = fchmod(fd, mode_t(mode))
    }

    public static func rename(_ from: String, _ to: String) throws {
        guard sysRename(from, to) == 0 else { throw FileIOError(op: "rename", path: "\(from) -> \(to)", code: errno) }
    }

    /// Size and free space (for unprivileged users) of the volume holding `path`.
    public static func space(_ path: String) -> (total: Int64, free: Int64)? {
        var fs = statvfs()
        guard statvfs(path, &fs) == 0 else { return nil }
        let unit = Int64(fs.f_frsize)
        return (Int64(fs.f_blocks) * unit, Int64(fs.f_bavail) * unit)
    }

    /// Absolute path with symlinks resolved, so the same folder always has one name.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        guard let resolved = realpath(absolute, nil) else { return absolute }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func mkdirs(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public static func mkdirs(parentOf path: String) throws {
        try mkdirs((path as NSString).deletingLastPathComponent)
    }

    /// Copies `count` bytes from `src` at `offset` to the current position of `dst`
    /// and returns their SHA-256.
    public static func copyRange(from src: Int32, srcPath: String, offset: Int64, count: Int, to dst: Int32, dstPath: String,
                                 buffer: UnsafeMutableRawBufferPointer) throws -> Data? {
        precondition(buffer.count >= count)
        let n = try pread(src, into: buffer.baseAddress!, count: count, offset: offset, path: srcPath)
        guard n == count else { return nil }
        let hash = Hashing.sha256(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        try write(dst, buffer.baseAddress!, count: count, path: dstPath)
        return hash
    }
}

/// Runs blocking file work on a GCD queue of the given QoS, keeping it off Swift's
/// cooperative pool. On macOS `.background` lets the system throttle CPU and disk I/O
/// when the machine is busy; on Linux the whole server runs niced instead.
public func runBlocking<T>(qos: DispatchQoS.QoSClass = .utility, _ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: qos).async {
            cont.resume(with: Result { try body() })
        }
    }
}

public func logLine(_ message: String) {
    var ts = localTime(Date(), "%Y-%m-%dT%H:%M:%S%z")
    ts.insert(":", at: ts.index(ts.endIndex, offsetBy: -2))  // +0200 -> +02:00
    FileHandle.standardError.write(Data("\(ts) \(message)\n".utf8))
}

/// Local time formatted by the C library (strftime), which reads /etc/localtime itself.
/// Foundation's time zones trap for every zone but UTC on QTS 5.2.11 (64 KB pages), so
/// the server must not touch them.
public func localTime(_ date: Date, _ format: String) -> String {
    var t = time_t(date.timeIntervalSince1970)
    var parts = tm()
    localtime_r(&t, &parts)
    var buf = [CChar](repeating: 0, count: 64)
    let n = strftime(&buf, buf.count, format, &parts)
    return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
