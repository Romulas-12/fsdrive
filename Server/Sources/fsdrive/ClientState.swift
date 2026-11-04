import Foundation
import FSDriveCore

/// What this device last agreed with the server about, per path. A local file whose
/// size, mtime and inode still match its entry is "unchanged" and safe to replace.
final class ClientState {
    struct Entry {
        var path: String
        var kind: NodeKind
        var fileId: Int64?
        var versionId: Int64?
        var size: Int64?
        var mtimeNs: Int64?
        var inode: Int64?
        var contentHash: Data?
        var manifest: Data?

        func matches(_ st: StatInfo) -> Bool {
            switch kind {
            case .dir: return st.kind == .dir
            case .file: return st.kind == .file && st.size == size && st.mtimeNs == mtimeNs && st.inode == inode
            }
        }
    }

    private let db: SQLiteDB

    init(path: String) throws {
        try FileIO.mkdirs(parentOf: path)
        db = try SQLiteDB(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS entry(
                path_key TEXT PRIMARY KEY, path TEXT NOT NULL, kind TEXT NOT NULL, file_id INTEGER, version_id INTEGER,
                size INTEGER, mtime_ns INTEGER, inode INTEGER, content_hash BLOB, manifest BLOB);
            CREATE INDEX IF NOT EXISTS entry_hash ON entry(content_hash);
            """)
    }

    var lastSeq: Int64? {
        get { (try? db.first("SELECT v FROM meta WHERE k = 'last_seq'") { Int64($0.text(0)) }) ?? nil }
        set { try? db.run("INSERT OR REPLACE INTO meta(k, v) VALUES('last_seq', ?)", [.text(newValue.map(String.init) ?? "")]) }
    }

    private static let columns = "path, kind, file_id, version_id, size, mtime_ns, inode, content_hash, manifest"

    private static func entry(_ r: SQLRow) -> Entry {
        Entry(path: r.text(0), kind: NodeKind(rawValue: r.text(1)) ?? .file, fileId: r.optInt(2), versionId: r.optInt(3), size: r.optInt(4),
              mtimeNs: r.optInt(5), inode: r.optInt(6), contentHash: r.optBlob(7), manifest: r.optBlob(8))
    }

    func entry(_ path: String) throws -> Entry? {
        try db.first("SELECT \(Self.columns) FROM entry WHERE path_key = ?", [.text(VPath.key(path))], Self.entry)
    }

    func all() throws -> [Entry] {
        var result = [Entry]()
        try db.query("SELECT \(Self.columns) FROM entry ORDER BY path") { result.append(Self.entry($0)) }
        return result
    }

    func subtree(_ path: String) throws -> [Entry] {
        let key = VPath.key(path)
        var result = [Entry]()
        try db.query("SELECT \(Self.columns) FROM entry WHERE path_key = ? OR (path_key > ? AND path_key < ?) ORDER BY path",
                     [.text(key), .text(key + "/"), .text(key + "0")]) { result.append(Self.entry($0)) }
        return result
    }

    /// An unchanged local file with this exact content, to clone instead of downloading.
    func entry(withHash hash: Data) throws -> Entry? {
        try db.first("SELECT \(Self.columns) FROM entry WHERE content_hash = ? AND kind = 'file' LIMIT 1", [.blob(hash)], Self.entry)
    }

    func put(_ e: Entry) throws {
        try db.run("INSERT OR REPLACE INTO entry(path_key, \(Self.columns)) VALUES(?,?,?,?,?,?,?,?,?,?)",
                   [.text(VPath.key(e.path)), .text(e.path), .text(e.kind.rawValue), .of(e.fileId), .of(e.versionId), .of(e.size),
                    .of(e.mtimeNs), .of(e.inode), .of(e.contentHash), .of(e.manifest)])
    }

    func remove(_ path: String) throws {
        try db.run("DELETE FROM entry WHERE path_key = ?", [.text(VPath.key(path))])
    }

    func moveSubtree(from old: String, to new: String) throws {
        try db.transaction {
            for var e in try subtree(old) {
                try remove(e.path)
                e.path = new + e.path.dropFirst(old.count)
                try put(e)
            }
        }
    }
}
