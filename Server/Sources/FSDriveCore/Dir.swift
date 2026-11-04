import CUserAccess
import Foundation

// File-scope wrappers: inside `Dir` and `FileAccess` the bare names would resolve to
// their own methods.
private func sysOpen(_ path: String, _ flags: Int32) -> Int32 { open(path, flags, 0) }
private func sysOpenAt(_ fd: Int32, _ name: String, _ flags: Int32, _ mode: mode_t) -> Int32 { openat(fd, name, flags, mode) }
private func sysFstatAt(_ fd: Int32, _ name: String) -> stat? {
    var st = stat()
    return fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil
}
private func sysFstat(_ fd: Int32) -> stat? {
    var st = stat()
    return fstat(fd, &st) == 0 ? st : nil
}

/// A folder held open by descriptor, for working inside folders their users can write
/// to. Paths below it are walked one component at a time with O_NOFOLLOW and every
/// operation is relative to a descriptor, so a symlink planted in a user's folder (or a
/// folder swapped for one between a check and its use) cannot send the server, which
/// runs as root on a NAS, anywhere else.
public final class Dir {
    public let fd: Int32
    /// For messages only; never used to reach the folder.
    public let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit { close(fd) }

    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Opens `path`, refusing a symlink as its last component. The folders above it are
    /// followed as usual, so they must be places regular users cannot change: an
    /// admin-chosen folder, or the folder holding the home folders.
    /// With `create`, a missing folder is made as in `sub`.
    public static func open(_ path: String, create: Bool = false, created: ((Dir) -> Void)? = nil) throws -> Dir {
        let ns = path as NSString
        let parentFd = sysOpen(ns.deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFd >= 0 else { throw FileIOError(op: "open", path: ns.deletingLastPathComponent, code: errno) }
        let parent = Dir(fd: parentFd, path: ns.deletingLastPathComponent)
        return try parent.child(ns.lastPathComponent, create: create, created: created)
    }

    /// A system folder (uploads, versions, trash): `open`, but only if it belongs to the
    /// server and nobody else can write to it. It may sit in a home folder others can
    /// write to (QTS home folders can be 0777), where a folder of someone else's could be
    /// put in its place; that is not a link, so `O_NOFOLLOW` alone would not catch it.
    public static func openSystem(_ path: String, create: Bool = false) throws -> Dir {
        let dir = try open(path, create: create)
        guard let st = sysFstat(dir.fd), st.st_uid == geteuid(), st.st_mode & 0o022 == 0 else {
            throw FileIOError(op: "open", path: path + " (not owned by the server, or writable by others)", code: EPERM)
        }
        return dir
    }

    /// A library folder: `open`, but only if it belongs to its user (`owner`) or to the
    /// server, so a folder someone else swapped in is neither filled nor served.
    public static func openLibrary(_ path: String, owner: UInt32?, create: Bool = false, created: ((Dir) -> Void)? = nil) throws -> Dir {
        let dir = try open(path, create: create, created: created)
        guard let owner else { return dir }
        guard let st = sysFstat(dir.fd), st.st_uid == geteuid() || UInt32(st.st_uid) == owner else {
            throw FileIOError(op: "open", path: path + " (owned by another user)", code: EPERM)
        }
        return dir
    }

    /// This folder's own attributes.
    public var info: StatInfo? { sysFstat(fd).map(StatInfo.init) }

    private static func components(_ rel: String) throws -> [String] {
        let parts = rel.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw FileIOError(op: "open", path: rel, code: EINVAL) }
        return parts
    }

    /// The folder at `rel` below this one ("" is this one). With `create`, missing
    /// folders are made, root-only until `created` gives them their owner.
    public func sub(_ rel: String, create: Bool = false, created: ((Dir) -> Void)? = nil) throws -> Dir {
        var cur = self
        for name in try Dir.components(rel) { cur = try cur.child(name, create: create, created: created) }
        return cur
    }

    private func child(_ name: String, create: Bool, created: ((Dir) -> Void)?) throws -> Dir {
        var fd = sysOpenAt(self.fd, name, Dir.flags, 0)
        var made = false
        if fd < 0 && errno == ENOENT && create {
            if mkdirat(self.fd, name, 0o700) == 0 {
                made = true
            } else if errno != EEXIST {
                throw FileIOError(op: "mkdir", path: path + "/" + name, code: errno)
            }
            fd = sysOpenAt(self.fd, name, Dir.flags, 0)
        }
        guard fd >= 0 else { throw FileIOError(op: "open", path: path + "/" + name, code: errno) }
        let dir = Dir(fd: fd, path: path + "/" + name)
        if made { created?(dir) }
        return dir
    }

    /// The folder holding `rel`, and the entry's own name in it.
    public func parent(of rel: String, create: Bool = false, created: ((Dir) -> Void)? = nil) throws -> (Dir, String) {
        var parts = try Dir.components(rel)
        guard let name = parts.popLast() else { throw FileIOError(op: "open", path: path + "/" + rel, code: EINVAL) }
        return (try sub(parts.joined(separator: "/"), create: create, created: created), name)
    }

    /// The entry itself, never what a symlink points to.
    public func stat(_ name: String) -> StatInfo? { sysFstatAt(fd, name).map(StatInfo.init) }

    /// Opens a regular file here; a symlink, FIFO or device in its place is refused
    /// (O_NONBLOCK keeps a FIFO from hanging the open itself).
    public func openFile(_ name: String, _ flags: Int32, mode: mode_t = 0o600, noCache: Bool = false) throws -> Int32 {
        let fd = sysOpenAt(self.fd, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode)
        guard fd >= 0 else { throw FileIOError(op: "open", path: path + "/" + name, code: errno) }
        guard let st = sysFstat(fd), st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw FileIOError(op: "open", path: path + "/" + name, code: EINVAL)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        #if canImport(Darwin)
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        #endif
        return fd
    }

    public func rename(_ name: String, to dir: Dir, as newName: String) throws {
        guard renameat(fd, name, dir.fd, newName) == 0 else {
            throw FileIOError(op: "rename", path: "\(path)/\(name) -> \(dir.path)/\(newName)", code: errno)
        }
    }

    /// Keeps a reference to the regular file `name` at `newName` in `dir` without copying
    /// bytes where possible: a hard link, an APFS clone, or else a copy with the same
    /// owner and mode.
    public func preserve(_ name: String, in dir: Dir, as newName: String) throws {
        guard stat(name)?.kind == .file else { throw FileIOError(op: "link", path: path + "/" + name, code: EINVAL) }
        if linkat(fd, name, dir.fd, newName, 0) == 0 { return }
        #if canImport(Darwin)
        if clonefileat(fd, name, dir.fd, newName, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        #endif
        let src = try openFile(name, O_RDONLY)
        defer { close(src) }
        let dst = try dir.openFile(newName, O_WRONLY | O_CREAT | O_EXCL)
        defer { close(dst) }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: FileIO.bufferSize, alignment: 16)
        defer { buf.deallocate() }
        while case let n = try FileIO.read(src, into: buf, count: FileIO.bufferSize, path: path + "/" + name), n > 0 {
            try FileIO.write(dst, buf, count: n, path: dir.path + "/" + newName)
        }
        if let st = sysFstat(src) { FileIO.setOwner(fd: dst, uid: UInt32(st.st_uid), gid: UInt32(st.st_gid), mode: UInt16(st.st_mode & 0o7777)) }
    }

    public func setMtime(_ name: String, ns: Int64) {
        var times = [
            timespec(tv_sec: 0, tv_nsec: utimeOmit),
            timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000)),
        ]
        _ = utimensat(fd, name, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// Owner and mode of this folder itself (best effort, as `FileIO.setOwner`).
    public func setOwner(uid: UInt32, gid: UInt32, mode: UInt16) { FileIO.setOwner(fd: fd, uid: uid, gid: gid, mode: mode) }

    public func unlink(_ name: String) { _ = unlinkat(fd, name, 0) }

    /// Removes an empty folder; returns errno on failure (ENOTEMPTY when it is not empty).
    public func rmdir(_ name: String) -> Int32? { unlinkat(fd, name, AT_REMOVEDIR) == 0 ? nil : errno }

    /// Deletes a file, or a folder with everything in it, without following links.
    public func removeTree(_ name: String) {
        if stat(name)?.kind == .dir, let d = try? child(name, create: false, created: nil) {
            for n in d.list() { d.removeTree(n) }
            _ = rmdir(name)
        } else {
            unlink(name)
        }
    }

    public func list() -> [String] {
        let copy = sysOpenAt(fd, ".", Dir.flags, 0)
        guard copy >= 0, let dirp = fdopendir(copy) else { return [] }
        defer { closedir(dirp) }
        var names = [String]()
        while let e = readdir(dirp) {
            let name = withUnsafePointer(to: &e.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}

/// The user a root server reads files for. On Linux the read happens under that user's
/// file-system identity, so the kernel applies their permissions and ACLs: a hard link
/// to someone else's file placed in their folder is refused as it would be over SMB.
public struct FileAccess: Sendable {
    public let uid: UInt32
    public let gid: UInt32
    public let groups: [UInt32]

    public init(user: String, uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
        var list = [gid_t](repeating: 0, count: 256)
        let n = fsdrive_user_groups(user, gid_t(gid), &list, Int32(list.count))
        groups = n > 0 ? list[0..<Int(n)].map { UInt32($0) } : [gid]
    }

    private static let rootGroups: [gid_t] = {
        var list = [gid_t](repeating: 0, count: 256)
        let n = fsdrive_thread_groups(&list, Int32(list.count))
        return n > 0 ? Array(list[0..<Int(n)]) : []
    }()

    /// Opens a regular file as this user. Runs synchronously on the calling thread, which
    /// is the one whose identity changes for the duration.
    public func open(_ dir: Dir, _ name: String, _ flags: Int32, noCache: Bool = false) throws -> Int32 {
        #if os(Linux)
        if geteuid() == 0 {
            let groups = self.groups.map { gid_t($0) }
            guard fsdrive_thread_become(uid_t(uid), gid_t(gid), groups, Int32(groups.count)) == 0 else {
                _ = fsdrive_thread_restore(FileAccess.rootGroups, Int32(FileAccess.rootGroups.count))
                throw FileIOError(op: "setfsuid", path: dir.path + "/" + name, code: errno)
            }
            defer {
                // Carrying on as the user would be worse than stopping.
                if fsdrive_thread_restore(FileAccess.rootGroups, Int32(FileAccess.rootGroups.count)) != 0 { fatalError("cannot restore root identity") }
            }
            return try dir.openFile(name, flags, noCache: noCache)
        }
        #endif
        // Elsewhere (a Mac, tests) the server is not root; the mode bits stand in.
        let fd = try dir.openFile(name, flags, noCache: noCache)
        guard let st = sysFstat(fd), permits(st, write: flags & O_ACCMODE != O_RDONLY) else {
            close(fd)
            throw FileIOError(op: "open", path: dir.path + "/" + name, code: EACCES)
        }
        return fd
    }

    private func permits(_ st: stat, write: Bool) -> Bool {
        let (r, w): (mode_t, mode_t) = UInt32(st.st_uid) == uid ? (S_IRUSR, S_IWUSR)
            : groups.contains(UInt32(st.st_gid)) ? (S_IRGRP, S_IWGRP) : (S_IROTH, S_IWOTH)
        return st.st_mode & (write ? w : r) != 0
    }
}
