import Foundation
import FSDriveCore

/// Brings the index in line with what is on disk: picks up files added, edited or
/// removed directly in Finder on the server. Runs at background QoS so macOS can
/// throttle it whenever the machine is busy.
struct Scanner {
    let store: Store

    func scanAll() async {
        guard let libs = try? await store.allLibraries() else { return }
        for lib in libs { await scan(lib) }
    }

    func scan(_ lib: Library) async {
        guard await store.beginScan(lib.id) else { return }
        do {
            try await run(lib)
        } catch {
            logLine("scan \(lib.name): \(error)")
        }
        await store.endScan(lib.id)
    }

    private func run(_ lib: Library) async throws {
        let started = Date()
        // A missing or emptied root usually means an unmounted disk or a dropped network
        // share, not a user deleting everything: never turn that into delete events.
        guard let root = FileIO.lstat(lib.dir), root.kind == .dir else {
            logLine("scan \(lib.name): \(lib.dir) is not available, skipped")
            return
        }
        // A folder someone else put in place of the library is not indexed into it.
        do { _ = try Dir.openLibrary(lib.dir, owner: lib.ownerUid) } catch {
            logLine("scan \(lib.name): skipped: \(error)")
            return
        }
        let disk = try await runBlocking(qos: .background) { try FileTree.walk(lib.dir) }
        var known = [String: NodeRecord]()
        for n in try await store.nodes(lib: lib.id) { known[VPath.key(n.path)] = n }
        if disk.isEmpty && !known.isEmpty {
            logLine("scan \(lib.name): folder is empty but \(known.count) items are indexed; skipped (delete them through a client)")
            return
        }

        var seen = Set<String>()
        var hashed = 0
        for (path, st) in disk {
            let key = VPath.key(path)
            seen.insert(key)
            let node = known[key]
            if st.kind == .dir {
                if node == nil { try await store.scanAddDir(lib: lib, path: path) }
                continue
            }
            if let node, node.kind == .file, node.size == st.size, node.mtimeNs == st.mtimeNs {
                if node.inode != st.inode { try await store.scanTouch(lib: lib, nodeId: node.id, stat: st) }
                continue
            }
            // Read as the library's user and never through a link: a file they could not
            // open themselves (e.g. a hard link to someone else's) stays out of the index.
            let file = FileRef(base: lib.dir, rel: path, root: .library(owner: lib.ownerUid))
            let access = store.access(lib)
            let manifest: Manifest
            do {
                manifest = try await runBlocking(qos: .background) {
                    let fd = try file.open(as: access, noCache: true)
                    defer { close(fd) }
                    return try Chunker.manifest(of: fd, path: file.path)
                }
            } catch let e as FileIOError where e.op == "open" {
                logLine("scan \(lib.name): \(path) skipped: \(e)")
                continue
            }
            hashed += 1
            if let node, node.kind == .file, node.contentHash == manifest.contentHash {
                try await store.scanTouch(lib: lib, nodeId: node.id, stat: st)
                continue
            }
            try await store.scanPutFile(lib: lib, path: path, stat: st, manifest: manifest, expectedVersion: node?.versionId)
        }
        // Deepest first so folders are empty in the index when they go.
        for (key, node) in known.sorted(by: { $0.key > $1.key }) where !seen.contains(key) {
            try await store.scanDelete(lib: lib, node: node)
        }
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        logLine("scan \(lib.name): \(disk.count) entries, \(hashed) hashed, \(secs)s")
    }
}
