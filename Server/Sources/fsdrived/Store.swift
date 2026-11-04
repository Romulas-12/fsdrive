import Foundation
import Hummingbird
import FSDriveCore

struct Library {
    var id: Int64
    var name: String
    var dir: String
    /// Uploads, versions and trash: must be on the same volume as `dir` so files move
    /// into place with rename() and versions are hard links.
    var sysDir: String
    /// QNAP user owning a personal library; nil for libraries made by the server admin.
    var owner: String?
    var ownerUid: UInt32?
}

struct NodeRecord {
    var id: Int64
    var path: String
    var kind: NodeKind
    var versionId: Int64?
    var size: Int64?
    var mtimeNs: Int64?
    var inode: Int64?
    var contentHash: Data?
    var parentId: Int64?

    var dto: NodeDTO {
        NodeDTO(fileId: id, kind: kind, path: path, versionId: versionId, size: size, mtimeNs: mtimeNs, contentHash: contentHash?.hex,
                parentId: parentId)
    }
}

struct UploadSession {
    var id: String
    var libId: Int64
    var path: String
    var baseVersionId: Int64?
    var mtimeNs: Int64
    var manifest: Manifest
    var device: String
    var received: Set<Data>
    /// Preallocated target file, inside the library's system folder.
    var dataPath: String
    /// Every offset at which each chunk occurs, and its length.
    let layout: [Data: (offsets: [Int64], length: Int)]

    init(id: String, libId: Int64, path: String, baseVersionId: Int64?, mtimeNs: Int64, manifest: Manifest, device: String, received: Set<Data>,
         dataPath: String) {
        self.dataPath = dataPath
        self.id = id
        self.libId = libId
        self.path = path
        self.baseVersionId = baseVersionId
        self.mtimeNs = mtimeNs
        self.manifest = manifest
        self.device = device
        self.received = received
        var layout = [Data: (offsets: [Int64], length: Int)]()
        for c in manifest.chunks { layout[c.hash, default: ([], c.length)].offsets.append(c.offset) }
        self.layout = layout
    }

    /// The folder holding the upload file and its name. The system folder is opened
    /// without following links: an older one may sit where its user can write.
    static func uploadsDir(_ dataPath: String) throws -> (Dir, String) {
        let ns = dataPath as NSString
        let sysDir = (ns.deletingLastPathComponent as NSString).deletingLastPathComponent
        return (try Dir.openSystem(sysDir).sub("uploads"), ns.lastPathComponent)
    }

    func openData(_ flags: Int32, noCache: Bool = false) throws -> Int32 {
        let (dir, name) = try UploadSession.uploadsDir(dataPath)
        return try dir.openFile(name, flags, noCache: noCache)
    }
}

/// A file below a library or its system folder, reached through descriptors so links
/// inside the user's folder are never followed.
struct FileRef: Hashable {
    enum Root: Hashable {
        case system
        /// A library folder and the uid of its user (nil: made by the server admin).
        case library(owner: UInt32?)
    }

    var base: String
    var rel: String
    var root: Root

    var path: String { base + "/" + rel }

    /// Read-only, with the rights of `access` (nil: libraries the server admin made).
    func open(as access: FileAccess?, noCache: Bool = false) throws -> Int32 {
        let top: Dir
        switch root {
        case .system: top = try Dir.openSystem(base)
        case .library(let owner): top = try Dir.openLibrary(base, owner: owner)
        }
        let (dir, name) = try top.parent(of: rel)
        if let access { return try access.open(dir, name, O_RDONLY, noCache: noCache) }
        return try dir.openFile(name, O_RDONLY, noCache: noCache)
    }
}

struct ChunkSource {
    var file: FileRef
    var offset: Int64
    var length: Int
}

/// Everything that mutates the database, plus the file-system operations that must
/// stay consistent with it (rename, link, mkdir), serialized by the actor.
actor Store {
    let root: String
    let db: SQLiteDB
    private var sessions: [String: UploadSession] = [:]
    private var scanning: Set<Int64> = []

    var systemDir: String { root + "/.system" }

    init(root: String) throws {
        self.root = root
        try FileIO.mkdirs(root + "/.system/uploads")
        // The database holds the gateway secret and the settings: the server's alone.
        // SQLite gives its -wal and -shm files the database file's mode.
        chmod(root + "/.system", 0o700)
        db = try SQLiteDB(path: root + "/.system/db.sqlite")
        for f in ["db.sqlite", "db.sqlite-wal", "db.sqlite-shm"] { chmod(root + "/.system/" + f, 0o600) }
        try db.exec(Store.schema)
        var columns = Set<String>()
        try db.query("PRAGMA table_info(change)") { columns.insert($0.text(1)) }
        if !columns.contains("parent_id") { try db.exec("ALTER TABLE change ADD COLUMN parent_id INTEGER") }
        try addColumns("library", ["sys_dir TEXT", "owner TEXT", "active INTEGER NOT NULL DEFAULT 1"])
        try addColumns("upload", ["data_path TEXT", "size INTEGER"])
        try addColumns("device", ["ssh_key TEXT"])
    }

    private func addColumns(_ table: String, _ defs: [String]) throws {
        var columns = Set<String>()
        try db.query("PRAGMA table_info(\(table))") { columns.insert($0.text(1)) }
        for def in defs where !columns.contains(String(def.split(separator: " ")[0])) {
            try db.exec("ALTER TABLE \(table) ADD COLUMN \(def)")
        }
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS library(
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, dir TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS node(
        id INTEGER PRIMARY KEY AUTOINCREMENT, lib_id INTEGER NOT NULL, path TEXT NOT NULL, path_key TEXT NOT NULL,
        kind TEXT NOT NULL, version_id INTEGER, size INTEGER, mtime_ns INTEGER, inode INTEGER, content_hash BLOB);
    CREATE UNIQUE INDEX IF NOT EXISTS node_path ON node(lib_id, path_key);
    CREATE TABLE IF NOT EXISTS version(
        id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL, lib_id INTEGER NOT NULL, size INTEGER NOT NULL,
        content_hash BLOB NOT NULL, manifest BLOB NOT NULL,
        blob TEXT,                       -- NULL: live file at the node's path; else relative to .system
        lost INTEGER NOT NULL DEFAULT 0, -- content overwritten outside the server
        device TEXT, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS chunk(hash BLOB NOT NULL, version_id INTEGER NOT NULL, offset INTEGER NOT NULL, len INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS chunk_hash ON chunk(hash);
    CREATE INDEX IF NOT EXISTS chunk_version ON chunk(version_id);
    CREATE TABLE IF NOT EXISTS change(
        seq INTEGER PRIMARY KEY AUTOINCREMENT, lib_id INTEGER NOT NULL, op TEXT NOT NULL, kind TEXT NOT NULL,
        file_id INTEGER NOT NULL, path TEXT NOT NULL, old_path TEXT, version_id INTEGER, size INTEGER, mtime_ns INTEGER,
        content_hash BLOB, device TEXT, at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS change_lib ON change(lib_id, seq);
    CREATE TABLE IF NOT EXISTS upload(
        id TEXT PRIMARY KEY, lib_id INTEGER NOT NULL, path TEXT NOT NULL, base_version INTEGER, mtime_ns INTEGER NOT NULL,
        manifest BLOB NOT NULL, device TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS upload_chunk(upload_id TEXT NOT NULL, hash BLOB NOT NULL, PRIMARY KEY(upload_id, hash));
    CREATE TABLE IF NOT EXISTS setting(k TEXT PRIMARY KEY, v TEXT NOT NULL);
    -- QNAP users who have a personal library. uid catches a deleted and re-created
    -- account that reuses a name.
    CREATE TABLE IF NOT EXISTS account(name TEXT PRIMARY KEY, uid INTEGER NOT NULL, lib_id INTEGER, status TEXT NOT NULL DEFAULT '');
    CREATE TABLE IF NOT EXISTS device(
        id INTEGER PRIMARY KEY AUTOINCREMENT, user TEXT NOT NULL, name TEXT NOT NULL, token_hash BLOB NOT NULL UNIQUE,
        created_at INTEGER NOT NULL, last_seen INTEGER);
    """

    var now: Int64 { Int64(Date().timeIntervalSince1970) }

    static let libraryColumns = """
        SELECT l.id, l.name, l.dir, l.sys_dir, l.owner, a.uid FROM library l LEFT JOIN account a ON a.name = l.owner
        """

    func libraryRecord(_ r: SQLRow) -> Library {
        Library(id: r.int(0), name: r.text(1), dir: r.text(2), sysDir: r.optText(3) ?? systemDir, owner: r.optText(4),
                ownerUid: r.optInt(5).map { UInt32($0) })
    }

    // MARK: Libraries

    /// Active libraries, all of them or only those owned by `owner`.
    func libraries(owner: String? = nil) throws -> [LibraryDTO] {
        var result = [LibraryDTO]()
        let filter = owner == nil ? "" : " AND owner = ?"
        try db.query("SELECT id, name FROM library WHERE active = 1\(filter) ORDER BY name", owner.map { [.text($0)] } ?? []) { row in
            result.append(LibraryDTO(id: row.int(0), name: row.text(1), latestSeq: 0))
        }
        for i in result.indices { result[i].latestSeq = try latestSeq(result[i].id) }
        return result
    }

    func library(_ id: Int64) throws -> Library {
        guard let lib = try db.first(Store.libraryColumns + " WHERE l.id = ?", [.int(id)], libraryRecord)
        else { throw HTTPError(.notFound, message: "library \(id) not found") }
        return lib
    }

    func allLibraries() throws -> [Library] {
        var result = [Library]()
        try db.query(Store.libraryColumns + " WHERE l.active = 1") { result.append(libraryRecord($0)) }
        return result
    }

    func createLibrary(name rawName: String, dir: String? = nil, owner: String) throws -> LibraryDTO {
        let name = try VPath.normalize(rawName)
        guard !name.contains("/") else { throw HTTPError(.badRequest, message: "library name cannot contain /") }
        let path = dir ?? "\(root)/files/\(owner)/\(name)"
        if dir == nil { try FileIO.mkdirs(path) }
        guard let st = FileIO.lstat(root + "/.system"), let target = FileIO.lstat(path) else {
            throw HTTPError(.badRequest, message: "\(path) does not exist")
        }
        guard target.kind == .dir else { throw HTTPError(.badRequest, message: "\(path) is not a folder") }
        // rename() into place and hard-linked versions need one file system.
        guard target.device == st.device else {
            throw HTTPError(.badRequest, message: "\(path) must be on the same volume as \(root)")
        }
        if try db.first("SELECT 1 FROM library WHERE name = ?", [.text(name)], { _ in true }) != nil {
            throw HTTPError(.conflict, message: "library \(name) already exists")
        }
        try db.run("INSERT INTO library(name, dir, created_at) VALUES(?, ?, ?)", [.text(name), .text(path), .int(now)])
        return LibraryDTO(id: db.lastInsertRowID, name: name, latestSeq: 0)
    }

    /// Moves a system folder (uploads, versions, trash) to `newDir`, for every library
    /// that uses it. Earlier versions kept it beside the library, where its user could
    /// replace it with a link.
    func relocateSystemFolder(from oldDir: String, to newDir: String) throws {
        let ns = newDir as NSString
        let target = try Dir.open(ns.deletingLastPathComponent)
        let old = oldDir as NSString
        // Only a folder that is the server's own comes along: one someone else put in its
        // place stays where it is.
        if target.stat(ns.lastPathComponent) == nil, let parent = try? Dir.open(old.deletingLastPathComponent),
           parent.stat(old.lastPathComponent)?.kind == .dir, (try? Dir.openSystem(oldDir)) != nil {
            do {
                try parent.rename(old.lastPathComponent, to: target, as: ns.lastPathComponent)
            } catch {
                logLine("system folder \(oldDir) stays behind, its versions and trash are not carried over: \(error)")
            }
        }
        let moved = try Dir.openSystem(newDir, create: true)
        moved.setOwner(uid: 0, gid: 0, mode: 0o750)
        _ = try moved.sub("uploads", create: true)
        try db.transaction {
            try db.run("UPDATE library SET sys_dir = ? WHERE sys_dir = ?", [.text(newDir), .text(oldDir)])
            try db.run("UPDATE upload SET data_path = ? || substr(data_path, length(?) + 1) WHERE substr(data_path, 1, length(?) + 1) = ? || '/'",
                       [.text(newDir), .text(oldDir), .text(oldDir), .text(oldDir)])
        }
        sessions = sessions.filter { !$0.value.dataPath.hasPrefix(oldDir + "/") }
        logLine("system folder \(oldDir) moved to \(newDir)")
    }

    func latestSeq(_ libId: Int64) throws -> Int64 {
        try db.first("SELECT COALESCE(MAX(seq), 0) FROM change WHERE lib_id = ?", [.int(libId)]) { $0.int(0) } ?? 0
    }

    // MARK: Reading

    func changes(lib: Int64, since: Int64, limit: Int) throws -> ChangesResponse {
        var changes = [ChangeDTO]()
        try db.query("""
            SELECT seq, op, kind, file_id, path, old_path, version_id, size, mtime_ns, content_hash, device, parent_id
            FROM change WHERE lib_id = ? AND seq > ? ORDER BY seq LIMIT ?
            """, [.int(lib), .int(since), .int(Int64(limit + 1))]) { r in
            changes.append(ChangeDTO(seq: r.int(0), op: ChangeOp(rawValue: r.text(1)) ?? .put, kind: NodeKind(rawValue: r.text(2)) ?? .file,
                                     fileId: r.int(3), path: r.text(4), oldPath: r.optText(5), versionId: r.optInt(6),
                                     size: r.optInt(7), mtimeNs: r.optInt(8), contentHash: r.optBlob(9)?.hex, device: r.optText(10),
                                     parentId: r.optInt(11)))
        }
        let hasMore = changes.count > limit
        if hasMore { changes.removeLast() }
        return ChangesResponse(changes: changes, latestSeq: try latestSeq(lib), hasMore: hasMore)
    }

    func tree(lib: Int64) throws -> TreeResponse {
        let seq = try latestSeq(lib)
        var all = try nodes(lib: lib)
        var ids = [String: Int64]()
        for n in all { ids[n.path] = n.id }
        for i in all.indices { all[i].parentId = VPath.parent(all[i].path).flatMap { ids[$0] } }
        return TreeResponse(seq: seq, nodes: all.map(\.dto))
    }

    /// Direct children of a folder (nil: the library root), for browsing on demand.
    func children(lib: Int64, parent: Int64?) throws -> TreeResponse {
        let seq = try latestSeq(lib)
        var result = [NodeRecord]()
        let cols = "SELECT id, path, kind, version_id, size, mtime_ns, inode, content_hash FROM node WHERE lib_id = ?"
        if let parent {
            guard let dir = try db.first("SELECT path FROM node WHERE id = ? AND lib_id = ? AND kind = 'dir'", [.int(parent), .int(lib)], { $0.text(0) })
            else { throw HTTPError(.notFound, message: "folder \(parent) not found") }
            let range = Store.subtreeRange(dir)
            try db.query(cols + " AND path_key > ? AND path_key < ? AND instr(substr(path_key, length(?) + 1), '/') = 0 ORDER BY path",
                         [.int(lib)] + range + [range[0]]) { result.append(Store.nodeRecord($0)) }
        } else {
            try db.query(cols + " AND instr(path_key, '/') = 0 ORDER BY path", [.int(lib)]) { result.append(Store.nodeRecord($0)) }
        }
        for i in result.indices { result[i].parentId = parent }
        return TreeResponse(seq: seq, nodes: result.map(\.dto))
    }

    func item(lib: Int64, id: Int64) throws -> NodeDTO {
        guard var n = try db.first("SELECT id, path, kind, version_id, size, mtime_ns, inode, content_hash FROM node WHERE id = ? AND lib_id = ?",
                                   [.int(id), .int(lib)], Store.nodeRecord)
        else { throw HTTPError(.notFound, message: "item \(id) not found") }
        n.parentId = try parentId(lib: lib, path: n.path)
        return n.dto
    }

    private func parentId(lib: Int64, path: String) throws -> Int64? {
        guard let p = VPath.parent(path) else { return nil }
        return try node(lib: lib, path: p)?.id
    }

    func nodes(lib: Int64) throws -> [NodeRecord] {
        var result = [NodeRecord]()
        try db.query("SELECT id, path, kind, version_id, size, mtime_ns, inode, content_hash FROM node WHERE lib_id = ? ORDER BY path",
                     [.int(lib)]) { result.append(Store.nodeRecord($0)) }
        return result
    }

    private static func nodeRecord(_ r: SQLRow) -> NodeRecord {
        NodeRecord(id: r.int(0), path: r.text(1), kind: NodeKind(rawValue: r.text(2)) ?? .file, versionId: r.optInt(3),
                   size: r.optInt(4), mtimeNs: r.optInt(5), inode: r.optInt(6), contentHash: r.optBlob(7))
    }

    func node(lib: Int64, path: String) throws -> NodeRecord? {
        try db.first("SELECT id, path, kind, version_id, size, mtime_ns, inode, content_hash FROM node WHERE lib_id = ? AND path_key = ?",
                     [.int(lib), .text(VPath.key(path))], Store.nodeRecord)
    }

    /// Whose rights reads from a library are made with: its owner, or nil for libraries
    /// the server admin made. An owner gone from the system reads nothing.
    nonisolated func access(_ lib: Library) -> FileAccess? {
        guard let owner = lib.owner else { return nil }
        guard let user = SystemUser.named(owner), user.uid == lib.ownerUid else { return FileAccess(user: owner, uid: 65534, gid: 65534) }
        return FileAccess(user: user.name, uid: user.uid, gid: user.gid)
    }

    func access(lib id: Int64) throws -> FileAccess? { access(try library(id)) }

    /// Where a version's bytes are, or nil if they are gone.
    func versionPath(_ versionId: Int64) throws -> (file: FileRef, manifest: Manifest, libId: Int64, access: FileAccess?)? {
        guard let v = try db.first("SELECT file_id, lib_id, manifest, blob, lost FROM version WHERE id = ?", [.int(versionId)], {
            (fileId: $0.int(0), libId: $0.int(1), manifest: $0.blob(2), blob: $0.optText(3), lost: $0.int(4) != 0)
        }), !v.lost else { return nil }
        let manifest = Manifest.decode(v.manifest)
        let lib = try library(v.libId)
        if let blob = v.blob { return (FileRef(base: lib.sysDir, rel: blob, root: .system), manifest, v.libId, access(lib)) }
        guard let node = try db.first("SELECT path FROM node WHERE id = ? AND version_id = ?", [.int(v.fileId), .int(versionId)], { $0.text(0) })
        else { return nil }
        return (FileRef(base: lib.dir, rel: node, root: .library(owner: lib.ownerUid)), manifest, v.libId, access(lib))
    }

    /// Chunks are shared only between libraries of one owner (a user's earlier locations
    /// count; libraries the server admin made share among themselves). Across users, a
    /// known hash would be enough to learn whether someone has a file, or to get its bytes.
    private static let sameOwner = "v.lib_id IN (SELECT id FROM library WHERE owner IS (SELECT owner FROM library WHERE id = ?))"

    /// Places on disk where a chunk with this hash should be found. Callers verify the
    /// bytes, since live files can change outside the server.
    func chunkSources(_ hashes: Set<Data>, lib: Int64) throws -> [Data: [ChunkSource]] {
        var result = [Data: [ChunkSource]]()
        var pathCache = [Int64: FileRef?]()
        for hash in hashes {
            var rows = [(Int64, Int64, Int)]()
            try db.query("""
                SELECT c.version_id, c.offset, c.len FROM chunk c JOIN version v ON v.id = c.version_id
                WHERE c.hash = ? AND v.lost = 0 AND \(Store.sameOwner) ORDER BY c.version_id DESC LIMIT 3
                """, [.blob(hash), .int(lib)]) { rows.append(($0.int(0), $0.int(1), Int($0.int(2)))) }
            for (vid, offset, len) in rows {
                if pathCache[vid] == nil { pathCache[vid] = try versionPath(vid)?.file }
                if let f = pathCache[vid] ?? nil { result[hash, default: []].append(ChunkSource(file: f, offset: offset, length: len)) }
            }
        }
        return result
    }

    // MARK: Uploads

    func createUpload(lib libId: Int64, request: CreateUploadRequest) throws -> (UploadSession, [Data]) {
        let lib = try library(libId)
        let path = try normalized(request.path)
        guard let manifest = Manifest(dto: request.chunks), manifest.contentHash.hex == request.contentHash else {
            throw HTTPError(.badRequest, message: "manifest does not match contentHash")
        }
        try checkLimits(lib: lib, path: path, size: manifest.size)
        let id = UUID().uuidString.lowercased()
        let uploads = try Dir.openSystem(lib.sysDir).sub("uploads", create: true)
        let dataPath = lib.sysDir + "/uploads/\(id).data"
        let session = UploadSession(id: id, libId: libId, path: path, baseVersionId: request.baseVersionId, mtimeNs: request.mtimeNs,
                                    manifest: manifest, device: request.device, received: [], dataPath: dataPath)
        // Preallocate the target so chunk uploads write straight to their final offsets
        // and every byte touches the disk once.
        let fd = try uploads.openFile("\(id).data", O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        defer { close(fd) }
        guard ftruncate(fd, off_t(manifest.size)) == 0 else { throw FileIOError(op: "ftruncate", path: dataPath, code: errno) }

        try db.run("INSERT INTO upload(id, lib_id, path, base_version, mtime_ns, manifest, device, created_at, data_path, size) VALUES(?,?,?,?,?,?,?,?,?,?)",
                   [.text(id), .int(libId), .text(path), .of(request.baseVersionId), .int(request.mtimeNs), .blob(manifest.encoded()),
                    .text(request.device), .int(now), .text(dataPath), .int(manifest.size)])
        sessions[id] = session

        var missing = [Data]()
        for hash in Set(manifest.chunks.map(\.hash)) {
            let known = try db.first("SELECT 1 FROM chunk c JOIN version v ON v.id = c.version_id WHERE c.hash = ? AND v.lost = 0 AND \(Store.sameOwner) LIMIT 1",
                                     [.blob(hash), .int(libId)]) { _ in true } ?? false
            if !known { missing.append(hash) }
        }
        return (session, missing)
    }

    /// Open uploads one user may have at once. Each preallocates its whole file, so many
    /// of them would hold disk space nobody uses.
    static let maxOpenUploads = 256

    /// Refuses an upload that is bigger than the owner's file limit, would take them over
    /// their quota, or would leave the volume almost full. Open uploads count as already used,
    /// since their space is reserved.
    private func checkLimits(lib: Library, path: String, size: Int64) throws {
        let limits = try lib.owner.flatMap { try settings().userLimits[$0] }
        let gb: Int64 = 1 << 30
        if let maxGB = limits?.maxFileSizeGB, size > Int64(maxGB) * gb {
            throw HTTPError(.init(code: 413), message: "Файл більший за дозволені \(maxGB) ГБ")
        }
        let pending = try db.first("""
            SELECT COUNT(*), COALESCE(SUM(u.size), 0) FROM upload u JOIN library l ON l.id = u.lib_id WHERE l.owner IS ?
            """, [.of(lib.owner)]) { ($0.int(0), $0.int(1)) } ?? (0, 0)
        if pending.0 >= Store.maxOpenUploads {
            throw HTTPError(.tooManyRequests, message: "Забагато незавершених завантажень; спробуйте пізніше")
        }
        if let owner = lib.owner, let quotaGB = limits?.quotaGB {
            // A file replaced in place frees what the old one took.
            let replaced = try node(lib: lib.id, path: path).flatMap(\.size) ?? 0
            let after = try usedBytes(owner: owner) + pending.1 + size - replaced
            if after > Int64(quotaGB) * gb {
                throw HTTPError(.init(code: 507), message: "Перевищено квоту \(quotaGB) ГБ для \(owner)")
            }
        }
        // Keep 2% of the volume (at least 2 GB) free for the NAS itself.
        if let fs = FileIO.space(lib.sysDir) {
            let reserve = max(2 * gb, fs.total / 50)
            if fs.free - pending.1 - size < reserve {
                throw HTTPError(.init(code: 507), message: "На NAS замало вільного місця для цього файлу")
            }
        }
    }

    /// Bytes a user's current files take (active libraries; versions and trash aside).
    func usedBytes(owner: String) throws -> Int64 {
        try db.first("""
            SELECT COALESCE(SUM(n.size), 0) FROM node n JOIN library l ON l.id = n.lib_id
            WHERE l.owner = ? AND l.active = 1 AND n.kind = 'file'
            """, [.text(owner)]) { $0.int(0) } ?? 0
    }

    func session(_ id: String) throws -> UploadSession {
        if let s = sessions[id] { return s }
        let legacyPath = systemDir + "/uploads/\(id).data"
        guard let s = try db.first("SELECT lib_id, path, base_version, mtime_ns, manifest, device, data_path FROM upload WHERE id = ?", [.text(id)], {
            UploadSession(id: id, libId: $0.int(0), path: $0.text(1), baseVersionId: $0.optInt(2), mtimeNs: $0.int(3),
                          manifest: Manifest.decode($0.blob(4)), device: $0.text(5), received: [], dataPath: $0.optText(6) ?? legacyPath)
        }) else { throw HTTPError(.notFound, message: "upload \(id) not found") }
        var session = s
        try db.query("SELECT hash FROM upload_chunk WHERE upload_id = ?", [.text(id)]) { session.received.insert($0.blob(0)) }
        sessions[id] = session
        return session
    }

    func markReceived(_ id: String, hash: Data) throws {
        try db.run("INSERT OR IGNORE INTO upload_chunk(upload_id, hash) VALUES(?, ?)", [.text(id), .blob(hash)])
        sessions[id]?.received.insert(hash)
    }

    private func dropUpload(_ id: String) throws {
        let dataPath = try session(id).dataPath
        sessions[id] = nil
        try db.run("DELETE FROM upload WHERE id = ?", [.text(id)])
        try db.run("DELETE FROM upload_chunk WHERE upload_id = ?", [.text(id)])
        if let up = try? UploadSession.uploadsDir(dataPath) { up.0.unlink(up.1) }
    }

    /// Removes uploads nobody finished within `age` seconds, with their preallocated
    /// files: a client that went away, or one creating uploads only to fill the disk.
    func dropStaleUploads(olderThan age: Int64) {
        var ids = [String]()
        try? db.query("SELECT id FROM upload WHERE created_at < ?", [.int(now - age)]) { ids.append($0.text(0)) }
        for id in ids {
            do { try dropUpload(id) } catch { logLine("upload \(id): \(error)") }
        }
        if !ids.isEmpty { logLine("dropped \(ids.count) unfinished uploads") }
    }

    /// Moves an assembled upload into the library. Runs after all chunks are in place
    /// and verified.
    func finalize(_ id: String) throws -> CommitResponse {
        let s = try session(id)
        let lib = try library(s.libId)
        var target = s.path
        var conflict = false
        let current = try node(lib: lib.id, path: target)

        if let cur = current {
            if cur.kind == .file && cur.contentHash == s.manifest.contentHash {
                // Same bytes already there (e.g. both sides got the same file): nothing to do.
                try dropUpload(id)
                return CommitResponse(status: "ok", change: ChangeDTO(seq: 0, op: .put, kind: .file, fileId: cur.id, path: cur.path,
                                                                      versionId: cur.versionId, size: cur.size, mtimeNs: cur.mtimeNs,
                                                                      contentHash: cur.contentHash?.hex))
            }
            if cur.kind == .dir || cur.versionId != s.baseVersionId { conflict = true }
        }
        if conflict { target = try freeConflictPath(lib: lib, path: target, device: s.device) }

        return try db.transaction {
            try ensureParents(lib: lib, path: target, device: s.device)
            let (parent, name) = try Dir.openLibrary(lib.dir, owner: lib.ownerUid).parent(of: target)
            let existing = conflict ? nil : current
            let fileId: Int64
            if let existing {
                fileId = existing.id
                if let old = existing.versionId {
                    try preserveOrLose(lib: lib, node: existing, versionId: old, parent: parent, name: name)
                }
            } else {
                try db.run("INSERT INTO node(lib_id, path, path_key, kind) VALUES(?, ?, ?, 'file')",
                           [.int(lib.id), .text(target), .text(VPath.key(target))])
                fileId = db.lastInsertRowID
            }
            let (uploads, dataName) = try UploadSession.uploadsDir(s.dataPath)
            let fd = try uploads.openFile(dataName, O_RDONLY)
            own(lib, fd: fd, dir: false)
            close(fd)
            try uploads.rename(dataName, to: parent, as: name)
            parent.setMtime(name, ns: s.mtimeNs)
            let st = parent.stat(name)
            let versionId = try insertVersion(lib: lib.id, fileId: fileId, manifest: s.manifest, device: s.device)
            try db.run("UPDATE node SET version_id = ?, size = ?, mtime_ns = ?, inode = ?, content_hash = ? WHERE id = ?",
                       [.int(versionId), .int(s.manifest.size), .of(st?.mtimeNs), .of(st?.inode), .blob(s.manifest.contentHash), .int(fileId)])
            let change = try record(lib: lib.id, op: .put, kind: .file, fileId: fileId, path: target, versionId: versionId,
                                    size: s.manifest.size, mtimeNs: st?.mtimeNs ?? s.mtimeNs, contentHash: s.manifest.contentHash, device: s.device)
            sessions[id] = nil
            try db.run("DELETE FROM upload WHERE id = ?", [.text(id)])
            try db.run("DELETE FROM upload_chunk WHERE upload_id = ?", [.text(id)])
            return CommitResponse(status: "ok", change: change, conflict: conflict)
        }
    }

    private func freeConflictPath(lib: Library, path: String, device: String) throws -> String {
        var candidate = VPath.conflictPath(path, device: device)
        var n = 2
        while try node(lib: lib.id, path: candidate) != nil || FileIO.lstat(lib.dir + "/" + candidate) != nil {
            candidate = VPath.conflictPath(path, device: "\(device) \(n)")
            n += 1
        }
        return candidate
    }

    /// Keeps the previous content as a hard link in .system/versions, unless it was
    /// already changed on disk behind our back, in which case it is unrecoverable.
    private func preserveOrLose(lib: Library, node: NodeRecord, versionId: Int64, parent: Dir, name: String) throws {
        let st = parent.stat(name)
        if let st, st.kind == .file, st.size == node.size, st.mtimeNs == node.mtimeNs, st.inode == node.inode {
            let dir = "versions/\(lib.id)/\(node.id)"
            try parent.preserve(name, in: try Dir.openSystem(lib.sysDir).sub(dir, create: true), as: "\(versionId)")
            let rel = dir + "/\(versionId)"
            try db.run("UPDATE version SET blob = ? WHERE id = ?", [.text(rel), .int(versionId)])
        } else {
            try db.run("UPDATE version SET lost = 1 WHERE id = ?", [.int(versionId)])
        }
    }

    private func insertVersion(lib: Int64, fileId: Int64, manifest: Manifest, device: String) throws -> Int64 {
        try db.run("INSERT INTO version(file_id, lib_id, size, content_hash, manifest, device, created_at) VALUES(?,?,?,?,?,?,?)",
                   [.int(fileId), .int(lib), .int(manifest.size), .blob(manifest.contentHash), .blob(manifest.encoded()), .text(device), .int(now)])
        let vid = db.lastInsertRowID
        for c in manifest.chunks {
            try db.run("INSERT INTO chunk(hash, version_id, offset, len) VALUES(?,?,?,?)",
                       [.blob(c.hash), .int(vid), .int(c.offset), .int(Int64(c.length))])
        }
        return vid
    }

    @discardableResult
    private func record(lib: Int64, op: ChangeOp, kind: NodeKind, fileId: Int64, path: String, oldPath: String? = nil,
                        versionId: Int64? = nil, size: Int64? = nil, mtimeNs: Int64? = nil, contentHash: Data? = nil,
                        device: String) throws -> ChangeDTO {
        let parent = try parentId(lib: lib, path: path)
        try db.run("""
            INSERT INTO change(lib_id, op, kind, file_id, path, old_path, version_id, size, mtime_ns, content_hash, device, at, parent_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.int(lib), .text(op.rawValue), .text(kind.rawValue), .int(fileId), .text(path), .of(oldPath), .of(versionId),
                  .of(size), .of(mtimeNs), .of(contentHash), .text(device), .int(now), .of(parent)])
        return ChangeDTO(seq: db.lastInsertRowID, op: op, kind: kind, fileId: fileId, path: path, oldPath: oldPath, versionId: versionId,
                         size: size, mtimeNs: mtimeNs, contentHash: contentHash?.hex, device: device, parentId: parent)
    }

    /// Files written for a user belong to that user, with the administrators group
    /// (gid 0 on QNAP, 101 on DSM) able to manage them; other users get nothing.
    nonisolated func own(_ lib: Library, fd: Int32, dir: Bool) {
        guard let uid = lib.ownerUid else { return }
        FileIO.setOwner(fd: fd, uid: uid, gid: NAS.current.adminGid, mode: dir ? 0o770 : 0o660)
    }

    /// For folders the server has just created.
    nonisolated func own(_ lib: Library, _ dir: Dir) { own(lib, fd: dir.fd, dir: true) }

    private func normalized(_ path: String) throws -> String {
        do { return try VPath.normalize(path) } catch { throw HTTPError(.badRequest, message: "\(error)") }
    }

    /// Creates missing parent folders on disk and in the index.
    private func ensureParents(lib: Library, path: String, device: String) throws {
        var root: Dir?
        for dir in VPath.ancestors(path) {
            if let n = try node(lib: lib.id, path: dir) {
                if n.kind != .dir { throw HTTPError(.conflict, message: "\(dir) is a file") }
                continue
            }
            if root == nil { root = try Dir.openLibrary(lib.dir, owner: lib.ownerUid) }
            _ = try root!.sub(dir, create: true) { self.own(lib, $0) }
            try insertDir(lib: lib, path: dir, device: device)
        }
    }

    private func insertDir(lib: Library, path: String, device: String) throws {
        let st = FileIO.lstat(lib.dir + "/" + path)
        try db.run("INSERT INTO node(lib_id, path, path_key, kind, mtime_ns, inode) VALUES(?, ?, ?, 'dir', ?, ?)",
                   [.int(lib.id), .text(path), .text(VPath.key(path)), .of(st?.mtimeNs), .of(st?.inode)])
        try record(lib: lib.id, op: .mkdir, kind: .dir, fileId: db.lastInsertRowID, path: path, device: device)
    }

    // MARK: Folder operations

    func apply(lib libId: Int64, _ req: OpRequest) throws -> OpResponse {
        let lib = try library(libId)
        let path = try normalized(req.path)
        switch req.op {
        case .mkdir:
            if let n = try node(lib: lib.id, path: path) {
                if n.kind == .dir { return OpResponse(change: nil) }
                throw HTTPError(.conflict, message: "\(path) is a file")
            }
            return try db.transaction {
                try ensureParents(lib: lib, path: path, device: req.device)
                _ = try Dir.openLibrary(lib.dir, owner: lib.ownerUid).sub(path, create: true) { self.own(lib, $0) }
                try insertDir(lib: lib, path: path, device: req.device)
                return OpResponse(change: try lastChange(lib.id))
            }
        case .delete:
            guard let n = try node(lib: lib.id, path: path) else { return OpResponse(change: nil) }
            return try db.transaction {
                if n.kind == .dir && req.recursive == true {
                    return OpResponse(change: try deleteTree(lib: lib, node: n, device: req.device))
                }
                return OpResponse(change: try delete(lib: lib, node: n, baseVersionId: req.baseVersionId, device: req.device))
            }
        case .move:
            guard let raw = req.newPath else { throw HTTPError(.badRequest, message: "newPath required") }
            let newPath = try normalized(raw)
            guard let n = try node(lib: lib.id, path: path) else { throw HTTPError(.notFound, message: "\(path) not found") }
            return try db.transaction { OpResponse(change: try move(lib: lib, node: n, to: newPath, device: req.device)) }
        case .put:
            throw HTTPError(.badRequest, message: "use uploads for file content")
        }
    }

    /// Bounds selecting every key under a folder: "a/" < "a/…" < "a0" ("0" follows "/").
    static func subtreeRange(_ path: String) -> [SQLValue] {
        let key = VPath.key(path)
        return [.text(key + "/"), .text(key + "0")]
    }

    private func lastChange(_ lib: Int64) throws -> ChangeDTO? {
        try changes(lib: lib, since: try latestSeq(lib) - 1, limit: 1).changes.first
    }

    private func delete(lib: Library, node n: NodeRecord, baseVersionId: Int64?, device: String) throws -> ChangeDTO {
        if n.kind == .file {
            if n.versionId != baseVersionId { throw HTTPError(.conflict, message: "\(n.path) changed on the server") }
            // Not reachable without following a link: gone as far as the library goes.
            if let vid = n.versionId, let live = try? Dir.openLibrary(lib.dir, owner: lib.ownerUid).parent(of: n.path), let st = live.0.stat(live.1) {
                let name = "\(n.id)-\(vid)"
                let rel = "trash/\(lib.id)/" + name
                let intact = st.size == n.size && st.mtimeNs == n.mtimeNs && st.inode == n.inode
                try live.0.rename(live.1, to: try Dir.openSystem(lib.sysDir).sub("trash/\(lib.id)", create: true), as: name)
                try db.run("UPDATE version SET blob = ?, lost = ? WHERE id = ?", [.text(rel), .int(intact ? 0 : 1), .int(vid)])
            }
        } else {
            let children = try db.first("SELECT COUNT(*) FROM node WHERE lib_id = ? AND path_key > ? AND path_key < ?",
                                        [.int(lib.id)] + Store.subtreeRange(n.path)) { $0.int(0) } ?? 0
            if children > 0 { throw HTTPError(.conflict, message: "\(n.path) is not empty") }
            removeDirectory(lib: lib, path: n.path, id: n.id)
        }
        try db.run("DELETE FROM node WHERE id = ?", [.int(n.id)])
        return try record(lib: lib.id, op: .delete, kind: n.kind, fileId: n.id, path: n.path, device: device)
    }

    /// Deletes a folder with everything in it: the whole folder moves into the server
    /// trash in one rename and each file's last version points there.
    private func deleteTree(lib: Library, node n: NodeRecord, device: String) throws -> ChangeDTO {
        var descendants = [NodeRecord]()
        try db.query("SELECT id, path, kind, version_id, size, mtime_ns, inode, content_hash FROM node WHERE lib_id = ? AND path_key > ? AND path_key < ?",
                     [.int(lib.id)] + Store.subtreeRange(n.path)) { descendants.append(Store.nodeRecord($0)) }
        let name = "dir-\(n.id)-\(UUID().uuidString.prefix(8))"
        let rel = "trash/\(lib.id)/" + name
        if let live = try? Dir.openLibrary(lib.dir, owner: lib.ownerUid).parent(of: n.path), live.0.stat(live.1) != nil {
            try live.0.rename(live.1, to: try Dir.openSystem(lib.sysDir).sub("trash/\(lib.id)", create: true), as: name)
        }
        let sys = try Dir.openSystem(lib.sysDir)
        for d in descendants.sorted(by: { $0.path > $1.path }) {
            if d.kind == .file, let vid = d.versionId {
                let sub = rel + String(d.path.dropFirst(n.path.count))
                let st = (try? sys.parent(of: sub)).flatMap { $0.0.stat($0.1) }
                let intact = st?.size == d.size && st?.mtimeNs == d.mtimeNs && st?.inode == d.inode
                try db.run("UPDATE version SET blob = ?, lost = ? WHERE id = ?", [.text(sub), .int(intact ? 0 : 1), .int(vid)])
            }
            try db.run("DELETE FROM node WHERE id = ?", [.int(d.id)])
            try record(lib: lib.id, op: .delete, kind: d.kind, fileId: d.id, path: d.path, device: device)
        }
        try db.run("DELETE FROM node WHERE id = ?", [.int(n.id)])
        return try record(lib: lib.id, op: .delete, kind: .dir, fileId: n.id, path: n.path, device: device)
    }

    /// Removes an indexed-empty folder. Finder litter is deleted; anything else that
    /// appeared since the last scan is kept in the trash rather than lost.
    nonisolated func removeDirectory(lib: Library, path: String, id: Int64) {
        guard let live = try? Dir.openLibrary(lib.dir, owner: lib.ownerUid).parent(of: path), let dir = try? live.0.sub(live.1) else { return }
        for name in dir.list() where VPath.isIgnored(name: name) { dir.removeTree(name) }
        if live.0.rmdir(live.1) == ENOTEMPTY, let trash = try? Dir.openSystem(lib.sysDir).sub("trash/\(lib.id)", create: true) {
            try? live.0.rename(live.1, to: trash, as: "dir-\(id)-\(UUID().uuidString.prefix(8))")
        }
    }

    private func move(lib: Library, node n: NodeRecord, to newPath: String, device: String) throws -> ChangeDTO {
        if newPath == n.path { throw HTTPError(.badRequest, message: "same path") }
        if n.kind == .dir && VPath.isInside(VPath.key(newPath), VPath.key(n.path)) {
            throw HTTPError(.badRequest, message: "cannot move a folder into itself")
        }
        if let other = try node(lib: lib.id, path: newPath), other.id != n.id {
            throw HTTPError(.conflict, message: "\(newPath) already exists")
        }
        try ensureParents(lib: lib, path: newPath, device: device)
        let root = try Dir.openLibrary(lib.dir, owner: lib.ownerUid)
        let (from, fromName) = try root.parent(of: n.path)
        let (to, toName) = try root.parent(of: newPath)
        try from.rename(fromName, to: to, as: toName)
        try db.run("UPDATE node SET path = ?, path_key = ? WHERE id = ?", [.text(newPath), .text(VPath.key(newPath)), .int(n.id)])
        if n.kind == .dir {
            var descendants = [(Int64, String)]()
            try db.query("SELECT id, path FROM node WHERE lib_id = ? AND path_key > ? AND path_key < ?",
                         [.int(lib.id)] + Store.subtreeRange(n.path)) {
                descendants.append(($0.int(0), $0.text(1)))
            }
            for (id, old) in descendants {
                let updated = newPath + old.dropFirst(n.path.count)
                try db.run("UPDATE node SET path = ?, path_key = ? WHERE id = ?", [.text(updated), .text(VPath.key(updated)), .int(id)])
            }
        }
        return try record(lib: lib.id, op: .move, kind: n.kind, fileId: n.id, path: newPath, oldPath: n.path, versionId: n.versionId,
                          size: n.size, mtimeNs: n.mtimeNs, contentHash: n.contentHash, device: device)
    }

    // MARK: Scan support (changes made directly in Finder on the server)

    func beginScan(_ lib: Int64) -> Bool { scanning.insert(lib).inserted }
    func endScan(_ lib: Int64) { scanning.remove(lib) }

    func scanAddDir(lib: Library, path: String) throws {
        guard try node(lib: lib.id, path: path) == nil else { return }
        try db.transaction {
            try ensureParents(lib: lib, path: path, device: "server")
            try insertDir(lib: lib, path: path, device: "server")
        }
    }

    /// Records a file found changed on disk. `expected` is the node state the scan saw;
    /// if an upload changed it meanwhile, the scan result is stale and dropped.
    func scanPutFile(lib: Library, path: String, stat: StatInfo, manifest: Manifest, expectedVersion: Int64?) throws {
        let current = try node(lib: lib.id, path: path)
        guard current?.versionId == expectedVersion, current?.kind != .dir else { return }
        guard FileIO.lstat(lib.dir + "/" + path) == stat else { return }
        try db.transaction {
            try ensureParents(lib: lib, path: path, device: "server")
            let fileId: Int64
            if let cur = current {
                fileId = cur.id
                if let old = cur.versionId { try db.run("UPDATE version SET lost = 1 WHERE id = ?", [.int(old)]) }
            } else {
                try db.run("INSERT INTO node(lib_id, path, path_key, kind) VALUES(?, ?, ?, 'file')",
                           [.int(lib.id), .text(path), .text(VPath.key(path))])
                fileId = db.lastInsertRowID
            }
            let vid = try insertVersion(lib: lib.id, fileId: fileId, manifest: manifest, device: "server")
            try db.run("UPDATE node SET version_id = ?, size = ?, mtime_ns = ?, inode = ?, content_hash = ? WHERE id = ?",
                       [.int(vid), .int(manifest.size), .int(stat.mtimeNs), .int(stat.inode), .blob(manifest.contentHash), .int(fileId)])
            try record(lib: lib.id, op: .put, kind: .file, fileId: fileId, path: path, versionId: vid, size: manifest.size,
                       mtimeNs: stat.mtimeNs, contentHash: manifest.contentHash, device: "server")
        }
    }

    /// Updates inode/mtime when only metadata changed (e.g. `touch`, or a copy restored
    /// with the same bytes), so the next scan does not hash the file again.
    func scanTouch(lib: Library, nodeId: Int64, stat: StatInfo) throws {
        try db.run("UPDATE node SET mtime_ns = ?, inode = ? WHERE id = ?", [.int(stat.mtimeNs), .int(stat.inode), .int(nodeId)])
    }

    func scanDelete(lib: Library, node n: NodeRecord) throws {
        guard FileIO.lstat(lib.dir + "/" + n.path) == nil, let cur = try node(lib: lib.id, path: n.path), cur.id == n.id else { return }
        try db.transaction {
            if let vid = n.versionId { try db.run("UPDATE version SET lost = 1 WHERE id = ?", [.int(vid)]) }
            try db.run("DELETE FROM node WHERE id = ?", [.int(n.id)])
            try record(lib: lib.id, op: .delete, kind: n.kind, fileId: n.id, path: n.path, device: "server")
        }
    }
}
