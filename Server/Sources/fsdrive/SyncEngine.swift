import Foundation
import FSDriveClientKit
import FSDriveCore

struct SyncSummary {
    var downloaded = 0
    var downloadedBytes: Int64 = 0
    var uploaded = 0
    var uploadedBytes: Int64 = 0
    var moved = 0
    var deleted = 0
    var conflicts = 0

    var isEmpty: Bool { downloaded + uploaded + moved + deleted + conflicts == 0 }

    var text: String {
        let fmt = ByteCountFormatter()
        return "↓ \(downloaded) (\(fmt.string(fromByteCount: downloadedBytes) )) · ↑ \(uploaded) (\(fmt.string(fromByteCount: uploadedBytes))) "
            + "· moved \(moved) · deleted \(deleted) · conflicts \(conflicts)"
    }
}

/// One library <-> one local folder. Each cycle pulls server changes first, then
/// pushes local ones; local edits are never overwritten (they become conflict copies).
final class SyncEngine {
    let api: APIClient
    let libId: Int64
    let dir: String
    let state: ClientState
    let device: String
    let transfer: FileTransfer
    private(set) var summary = SyncSummary()

    init(api: APIClient, libId: Int64, dir: String, state: ClientState, device: String) {
        self.api = api
        self.libId = libId
        self.dir = dir
        self.state = state
        self.device = device
        transfer = FileTransfer(api: api, libId: libId, device: device)
    }

    private func local(_ path: String) -> String { dir + "/" + path }

    func syncOnce() async throws -> SyncSummary {
        summary = SyncSummary()
        try await pull()
        try await push()
        return summary
    }

    // MARK: Pull

    private func pull() async throws {
        guard let since = state.lastSeq else {
            let tree = try await api.tree(lib: libId)
            for node in tree.nodes {
                switch node.kind {
                case .dir: try applyMkdir(node.path, fileId: node.fileId)
                case .file:
                    try await applyFile(path: node.path, fileId: node.fileId, versionId: node.versionId, mtimeNs: node.mtimeNs,
                                        contentHash: node.contentHash)
                }
            }
            state.lastSeq = tree.seq
            return
        }
        var seq = since
        var needsTree = false
        while true {
            let page = try await api.changes(lib: libId, since: seq)
            for c in page.changes {
                switch c.op {
                case .mkdir: try applyMkdir(c.path, fileId: c.fileId)
                case .put:
                    try await applyFile(path: c.path, fileId: c.fileId, versionId: c.versionId, mtimeNs: c.mtimeNs, contentHash: c.contentHash)
                case .delete: try applyDelete(c.path, kind: c.kind)
                case .move:
                    if try !applyMove(from: c.oldPath ?? c.path, to: c.path, kind: c.kind) {
                        if c.kind == .file {
                            try applyDelete(c.oldPath ?? c.path, kind: .file)
                            try await applyFile(path: c.path, fileId: c.fileId, versionId: c.versionId, mtimeNs: c.mtimeNs,
                                                contentHash: c.contentHash)
                        } else {
                            try applyDelete(c.oldPath ?? c.path, kind: .dir)
                            needsTree = true
                        }
                    }
                }
                seq = c.seq
                state.lastSeq = seq
            }
            if !page.hasMore { break }
        }
        if needsTree {
            // A folder moved on the server could not be moved here: fetch what is missing.
            for node in try await api.tree(lib: libId).nodes {
                switch node.kind {
                case .dir: try applyMkdir(node.path, fileId: node.fileId)
                case .file:
                    try await applyFile(path: node.path, fileId: node.fileId, versionId: node.versionId, mtimeNs: node.mtimeNs,
                                        contentHash: node.contentHash)
                }
            }
        }
    }

    private func applyMkdir(_ path: String, fileId: Int64) throws {
        // Already known here (often our own mkdir coming back in the journal). If it is
        // missing on disk the user deleted it, and the push that follows sends that on;
        // recreating it would undo the delete.
        if try state.entry(path)?.kind == .dir { return }
        if let st = FileIO.lstat(local(path)), st.kind != .dir {
            try keepAsConflict(path)
        }
        try FileIO.mkdirs(local(path))
        try state.put(.init(path: path, kind: .dir, fileId: fileId))
    }

    /// Renames a local item out of the way; the next push uploads it as a new file.
    private func keepAsConflict(_ path: String) throws {
        let target = VPath.conflictPath(path, device: device)
        try FileIO.rename(local(path), local(target))
        try state.remove(path)
        summary.conflicts += 1
        logLine("conflict: kept local \(path) as \(target)")
    }

    private func applyFile(path: String, fileId: Int64, versionId: Int64?, mtimeNs: Int64?, contentHash: String?) async throws {
        guard let versionId, let remoteHash = contentHash.flatMap({ Data(hex: $0) }) else { return }
        let entry = try state.entry(path)
        if entry?.versionId == versionId { return }

        let livePath = local(path)
        var reuse: [(path: String, manifest: Manifest)] = []
        let before = FileIO.lstat(livePath)
        if let st = before {
            if st.kind == .dir {
                try keepAsConflict(path)
            } else if let entry, entry.matches(st) {
                if let m = entry.manifest { reuse.append((livePath, Manifest.decode(m))) }
            } else {
                // Changed here and on the server. Identical content is not a conflict.
                let m = try await runBlocking { try Chunker.manifest(ofFileAt: livePath) }
                if m.contentHash == remoteHash {
                    try record(path: path, fileId: fileId, versionId: versionId, st: st, manifest: m)
                    return
                }
                try keepAsConflict(path)
                reuse.append((local(VPath.conflictPath(path, device: device)), m))
            }
        }

        let remote = try await api.manifest(lib: libId, version: versionId)
        guard let manifest = Manifest(dto: remote.chunks) else { throw APIError(status: 0, message: "bad manifest for \(path)") }
        try FileIO.mkdirs(parentOf: livePath)
        let temp = (livePath as NSString).deletingLastPathComponent + "/.fsdrive-\(UUID().uuidString).part"
        defer { unlink(temp) }

        var cloned = false
        if let same = try state.entry(withHash: remoteHash), let st = FileIO.lstat(local(same.path)), same.matches(st) {
            // Same bytes already here under another name: an APFS clone costs no space or I/O.
            cloned = clonefile(local(same.path), temp, 0) == 0
        }
        if !cloned {
            let fetched = try await transfer.download(versionId: versionId, manifest: manifest, to: temp, reuse: reuse)
            summary.downloadedBytes += fetched
        }
        if let mtimeNs { FileIO.setMtime(temp, ns: mtimeNs) }
        // The user may have touched the file while we were downloading.
        let now = FileIO.lstat(livePath)
        if before != nil && now != nil && now != before { return }
        if before == nil && now != nil { return }
        try FileIO.rename(temp, livePath)
        guard let st = FileIO.lstat(livePath) else { return }
        try record(path: path, fileId: fileId, versionId: versionId, st: st, manifest: manifest)
        summary.downloaded += 1
    }

    private func record(path: String, fileId: Int64?, versionId: Int64?, st: StatInfo, manifest: Manifest) throws {
        try state.put(.init(path: path, kind: .file, fileId: fileId, versionId: versionId, size: st.size, mtimeNs: st.mtimeNs,
                            inode: st.inode, contentHash: manifest.contentHash, manifest: manifest.encoded()))
    }

    private func applyDelete(_ path: String, kind: NodeKind) throws {
        let entries = try state.subtree(path)
        guard !entries.isEmpty else { return }
        // Files first, deepest folders last. Local edits survive and get re-uploaded.
        for e in entries.reversed() {
            let p = local(e.path)
            if let st = FileIO.lstat(p) {
                switch e.kind {
                case .file:
                    if e.matches(st) {
                        unlink(p)
                        summary.deleted += 1
                    }
                case .dir:
                    let fm = FileManager.default
                    for name in (try? fm.contentsOfDirectory(atPath: p)) ?? [] where VPath.isIgnored(name: name) {
                        try? fm.removeItem(atPath: p + "/" + name)
                    }
                    rmdir(p)
                }
            }
            try state.remove(e.path)
        }
    }

    private func applyMove(from old: String, to new: String, kind: NodeKind) throws -> Bool {
        guard let entry = try state.entry(old), let st = FileIO.lstat(local(old)), entry.matches(st),
              FileIO.lstat(local(new)) == nil else { return false }
        try FileIO.mkdirs(parentOf: local(new))
        try FileIO.rename(local(old), local(new))
        try state.moveSubtree(from: old, to: new)
        summary.moved += 1
        return true
    }

    // MARK: Push

    private func push() async throws {
        let disk = try await runBlocking { try FileTree.walk(self.dir) }
        var known = [String: ClientState.Entry]()
        for e in try state.all() { known[VPath.key(e.path)] = e }
        var seen = Set<String>()

        var newDirs = [String]()
        var changed = [(path: String, st: StatInfo, entry: ClientState.Entry?)]()
        for (path, st) in disk {
            let key = VPath.key(path)
            seen.insert(key)
            let entry = known[key]
            if st.kind == .dir {
                if entry?.kind != .dir { newDirs.append(path) }
            } else if entry == nil || !(entry!.matches(st)) {
                changed.append((path, st, entry))
            }
        }
        var gone = known.values.filter { !seen.contains(VPath.key($0.path)) }

        for path in newDirs {
            let r = try await api.op(lib: libId, OpRequest(op: .mkdir, path: path, device: device))
            try state.put(.init(path: path, kind: .dir, fileId: r.change?.fileId))
        }

        for item in changed {
            let full = local(item.path)
            let manifest: Manifest
            do {
                manifest = try await runBlocking { try Chunker.manifest(ofFileAt: full) }
            } catch {
                logLine("skip \(item.path): \(error)")
                continue
            }
            if let e = item.entry, e.kind == .file, e.contentHash == manifest.contentHash {
                try record(path: item.path, fileId: e.fileId, versionId: e.versionId, st: item.st, manifest: manifest)
                continue
            }
            // A new file with the content of one that vanished is a rename: no bytes move.
            if item.entry == nil, let i = gone.firstIndex(where: { $0.kind == .file && $0.contentHash == manifest.contentHash }) {
                let old = gone.remove(at: i)
                do {
                    _ = try await api.op(lib: libId, OpRequest(op: .move, path: old.path, newPath: item.path, device: device))
                    try state.remove(old.path)
                    try record(path: item.path, fileId: old.fileId, versionId: old.versionId, st: item.st, manifest: manifest)
                    summary.moved += 1
                    continue
                } catch let error as APIError where error.status == 404 || error.status == 409 {
                    gone.append(old)
                }
            }
            do {
                try await upload(path: item.path, st: item.st, manifest: manifest, base: item.entry?.kind == .file ? item.entry?.versionId : nil)
            } catch is LocalFileChanged {
                continue
            }
        }

        for e in gone.sorted(by: { $0.path > $1.path }) {
            do {
                _ = try await api.op(lib: libId, OpRequest(op: .delete, path: e.path, baseVersionId: e.versionId, device: device))
                summary.deleted += 1
            } catch let error as APIError where error.status == 409 {
                // Changed on the server since we saw it; the next pull brings it back.
                logLine("not deleted on server (changed there): \(e.path)")
            }
            try state.remove(e.path)
        }
    }

    private func upload(path: String, st: StatInfo, manifest: Manifest, base: Int64?) async throws {
        let full = local(path)
        let result = try await transfer.upload(file: full, as: path, base: base, mtimeNs: st.mtimeNs, manifest: manifest)
        summary.uploadedBytes += result.sentBytes
        let change = result.change
        if result.conflict {
            // The server kept our bytes under a conflict name; mirror that locally so the
            // server's version can come down to the original path.
            try FileIO.mkdirs(parentOf: local(change.path))
            try FileIO.rename(full, local(change.path))
            summary.conflicts += 1
            let moved = FileIO.lstat(local(change.path)) ?? st
            try record(path: change.path, fileId: change.fileId, versionId: change.versionId, st: moved, manifest: manifest)
            logLine("conflict: \(path) changed on the server; yours is \(change.path)")
        } else {
            try record(path: path, fileId: change.fileId, versionId: change.versionId, st: st, manifest: manifest)
        }
        summary.uploaded += 1
    }
}
