import FileProvider
import FSDriveClientKit
import FSDriveCore

/// Sync anchor: the last journal sequence seen for every library.
struct Anchor: Codable {
    var seqs: [Int64: Int64]

    init(seqs: [Int64: Int64]) { self.seqs = seqs }

    init?(_ anchor: NSFileProviderSyncAnchor) {
        guard let decoded = try? JSONDecoder().decode(Anchor.self, from: anchor.rawValue) else { return nil }
        self = decoded
    }

    var syncAnchor: NSFileProviderSyncAnchor { NSFileProviderSyncAnchor((try? JSONEncoder().encode(self)) ?? Data()) }

    static func current(_ libraries: [LibraryDTO]) -> Anchor {
        Anchor(seqs: Dictionary(uniqueKeysWithValues: libraries.map { ($0.id, $0.latestSeq) }))
    }
}

final class Enumerator: NSObject, NSFileProviderEnumerator {
    let container: ItemID
    let api: APIClient?

    init(container: ItemID, api: APIClient?) {
        self.container = container
        self.api = api
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                guard let api else { throw NSFileProviderError(.notAuthenticated) }
                observer.didEnumerate(try await items(api))
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.map(error))
            }
        }
    }

    private func items(_ api: APIClient) async throws -> [NSFileProviderItem] {
        switch container {
        case .root, .library:
            let lib = try await FileProviderExtension.personalLibrary(api)
            return try await api.children(lib: lib.id, parent: nil).nodes.map { Item(lib: lib.id, node: $0) }
        case .node(let lib, let id):
            return try await api.children(lib: lib, parent: id).nodes.map { Item(lib: lib, node: $0) }
        case .workingSet:
            // Everything, so Spotlight can index names and a full resync sees all items.
            let lib = try await FileProviderExtension.personalLibrary(api)
            return try await api.tree(lib: lib.id).nodes.map { Item(lib: lib.id, node: $0) }
        case .trash:
            return []
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                guard let api else { throw NSFileProviderError(.notAuthenticated) }
                let lib = try await FileProviderExtension.personalLibrary(api)
                guard container == .workingSet, let anchor = Anchor(syncAnchor) else {
                    // Only the working set reports changes in a replicated provider.
                    observer.finishEnumeratingChanges(upTo: Anchor.current([lib]).syncAnchor, moreComing: false)
                    return
                }
                // The admin moved this user's files elsewhere (another storage mode): the
                // old item IDs mean nothing now, so macOS has to enumerate from scratch.
                guard var seq = anchor.seqs[lib.id], anchor.seqs.count == 1 else {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                var updated = [NSFileProviderItem]()
                var deleted = [NSFileProviderItemIdentifier]()
                while seq < lib.latestSeq {
                    let page = try await api.changes(lib: lib.id, since: seq)
                    for c in page.changes {
                        let id = ItemID.node(lib: lib.id, id: c.fileId).identifier
                        updated.removeAll { $0.itemIdentifier == id }
                        if c.op == .delete {
                            deleted.append(id)
                        } else {
                            deleted.removeAll { $0 == id }
                            updated.append(Item(lib: lib.id, change: c))
                        }
                        seq = c.seq
                    }
                    if !page.hasMore { break }
                }
                for raw in Pinned.takePending() {
                    let id = NSFileProviderItemIdentifier(raw)
                    if !updated.contains(where: { $0.itemIdentifier == id }), let item = try? await FileProviderExtension.lookup(id, api: api) {
                        updated.append(item)
                    }
                }
                if !updated.isEmpty { observer.didUpdate(updated) }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                observer.finishEnumeratingChanges(upTo: Anchor.current([lib]).syncAnchor, moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.map(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            var libs = [LibraryDTO]()
            if let api, let lib = try? await FileProviderExtension.personalLibrary(api) { libs = [lib] }
            completionHandler(Anchor.current(libs).syncAnchor)
        }
    }
}
