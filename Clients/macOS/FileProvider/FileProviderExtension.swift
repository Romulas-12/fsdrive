import FileProvider
import OSLog
import UniformTypeIdentifiers
import FSDriveClientKit
import FSDriveCore

/// Replicated File Provider: macOS keeps the local copy and asks us only to fetch
/// content and to apply local edits to the server — the same model iCloud Drive uses.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    let domain: NSFileProviderDomain
    let config: AccountConfig?
    let api: APIClient?
    lazy var manager = NSFileProviderManager(for: domain)

    var device: String { config?.device ?? Host.current().localizedName ?? "Mac" }

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        config = AccountConfig.load()
        api = config?.api
        super.init()
    }

    func invalidate() {}

    // MARK: Errors

    static let log = Logger(subsystem: "com.romulas.fsdrive", category: "fileprovider")

    static func map(_ error: Error) -> Error {
        log.error("\(String(describing: error), privacy: .public)")
        if (error as NSError).domain == NSFileProviderErrorDomain { return error }
        if let e = error as? APIError {
            switch e.status {
            case 401, 403: return NSFileProviderError(.notAuthenticated)
            case 404: return NSFileProviderError(.noSuchItem)
            default: return NSFileProviderError(.serverUnreachable)
            }
        }
        if error is URLError { return NSFileProviderError(.serverUnreachable) }
        return error
    }

    private func requireAPI() throws -> APIClient {
        guard let api else { throw NSFileProviderError(.notAuthenticated) }
        return api
    }

    // MARK: Items

    /// The signed-in user's own library, shown as the FSDrive root.
    static func personalLibrary(_ api: APIClient) async throws -> LibraryDTO {
        guard let lib = try await api.libraries().first else { throw NSFileProviderError(.notAuthenticated) }
        return lib
    }

    static func lookup(_ identifier: NSFileProviderItemIdentifier, api: APIClient) async throws -> Item {
        switch ItemID(identifier) {
        case .root:
            return Item.root
        case .library(let lib):
            guard let library = try await api.libraries().first(where: { $0.id == lib }) else { throw NSFileProviderError(.noSuchItem) }
            return Item(library: library)
        case .node(let lib, let id):
            return Item(lib: lib, node: try await api.item(lib: lib, id: id))
        case .workingSet, .trash:
            throw NSFileProviderError(.noSuchItem)
        }
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        Task {
            do { completionHandler(try await Self.lookup(identifier, api: try requireAPI()), nil) } catch { completionHandler(nil, Self.map(error)) }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        Enumerator(container: ItemID(containerItemIdentifier), api: api)
    }

    // MARK: Content

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let api = try requireAPI()
                guard case .node(let lib, let id) = ItemID(itemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                let node = try await api.item(lib: lib, id: id)
                guard let versionId = node.versionId else { throw NSFileProviderError(.noSuchItem) }
                let remote = try await api.manifest(lib: lib, version: versionId)
                guard let manifest = Manifest(dto: remote.chunks) else { throw NSFileProviderError(.serverUnreachable) }
                progress.totalUnitCount = max(manifest.size, 1)
                guard let manager else { throw NSFileProviderError(.providerNotFound) }
                let temp = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
                _ = try await FileTransfer(api: api, libId: lib, device: device)
                    .download(versionId: versionId, manifest: manifest, to: temp.path) { progress.completedUnitCount += $0 }
                completionHandler(temp, Item(lib: lib, node: node), nil)
            } catch {
                completionHandler(nil, nil, Self.map(error))
            }
        }
        return progress
    }

    /// Library-relative path for a new child of `parent`, plus the library it lives in.
    private func childPath(parent: NSFileProviderItemIdentifier, name: String, api: APIClient) async throws -> (lib: Int64, path: String) {
        switch ItemID(parent) {
        case .root: return (try await Self.personalLibrary(api).id, name)
        case .library(let lib): return (lib, name)
        case .node(let lib, let id): return (lib, try await api.item(lib: lib, id: id).path + "/" + name)
        default: throw NSFileProviderError(.noSuchItem)
        }
    }

    private func upload(_ url: URL, lib: Int64, path: String, base: Int64?, modified: Date?, progress: Progress, api: APIClient) async throws -> UploadResult {
        let manifest = try await runBlocking { try Chunker.manifest(ofFileAt: url.path) }
        progress.totalUnitCount = max(manifest.size, 1)
        let mtime = Int64((modified ?? Date()).timeIntervalSince1970 * 1e9)
        return try await FileTransfer(api: api, libId: lib, device: device)
            .upload(file: url.path, as: path, base: base, mtimeNs: mtime, manifest: manifest) { progress.completedUnitCount += $0 }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let api = try requireAPI()
                let isFolder = itemTemplate.contentType == .folder
                let (lib, path) = try await childPath(parent: itemTemplate.parentItemIdentifier, name: itemTemplate.filename, api: api)
                if isFolder {
                    let r = try await api.op(lib: lib, OpRequest(op: .mkdir, path: path, device: device))
                    if let change = r.change {
                        completionHandler(Item(lib: lib, change: change), [], false, nil)
                    } else {
                        // Already there (e.g. created on another Mac at the same time).
                        let parentId: Int64? = if case .node(_, let id) = ItemID(itemTemplate.parentItemIdentifier) { id } else { nil }
                        let existing = try await api.children(lib: lib, parent: parentId).nodes.first { $0.path == path }
                        guard let existing else { throw NSFileProviderError(.noSuchItem) }
                        completionHandler(Item(lib: lib, node: existing), [], false, nil)
                    }
                    return
                }
                guard itemTemplate.contentType != .symbolicLink, let url else { throw NSFileProviderError(.cannotSynchronize) }
                let result = try await upload(url, lib: lib, path: path, base: nil, modified: itemTemplate.contentModificationDate ?? nil,
                                              progress: progress, api: api)
                // If the name was taken, the server stored it under a conflict name and
                // returning that name makes Finder rename the local copy to match.
                completionHandler(Item(lib: lib, change: result.change), [], false, nil)
            } catch {
                completionHandler(nil, [], false, Self.map(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let api = try requireAPI()
                guard case .node(let lib, let id) = ItemID(item.itemIdentifier) else {
                    // Libraries themselves cannot be renamed from Finder yet.
                    completionHandler(try await Self.lookup(item.itemIdentifier, api: api), [], false, nil)
                    return
                }
                var node = try await api.item(lib: lib, id: id)

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let target = try await childPath(parent: item.parentItemIdentifier, name: item.filename, api: api)
                    guard target.lib == lib else { throw NSFileProviderError(.cannotSynchronize) }
                    if target.path != node.path {
                        _ = try await api.op(lib: lib, OpRequest(op: .move, path: node.path, newPath: target.path, device: device))
                        node = try await api.item(lib: lib, id: id)
                    }
                }

                var fetchAgain = false
                if changedFields.contains(.contents), let newContents {
                    let result = try await upload(newContents, lib: lib, path: node.path, base: version.serverVersionId,
                                                  modified: item.contentModificationDate ?? nil, progress: progress, api: api)
                    if result.conflict {
                        // Someone else changed it first: our bytes became a separate conflict
                        // copy on the server, and this item goes back to the server's version.
                        fetchAgain = true
                    }
                    node = try await api.item(lib: lib, id: id)
                }
                completionHandler(Item(lib: lib, node: node), [], fetchAgain, nil)
            } catch {
                completionHandler(nil, [], false, Self.map(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        Task {
            do {
                let api = try requireAPI()
                guard case .node(let lib, let id) = ItemID(identifier) else { throw NSFileProviderError(.deletionRejected) }
                let node: NodeDTO
                do { node = try await api.item(lib: lib, id: id) } catch let e as APIError where e.status == 404 {
                    completionHandler(nil)  // already gone
                    return
                }
                do {
                    _ = try await api.op(lib: lib, OpRequest(op: .delete, path: node.path,
                                                             baseVersionId: node.kind == .file ? version.serverVersionId : nil,
                                                             device: device, recursive: options.contains(.recursive)))
                    completionHandler(nil)
                } catch let e as APIError where e.status == 409 {
                    throw NSFileProviderError(.deletionRejected)
                }
            } catch {
                completionHandler(Self.map(error))
            }
        }
        return Progress()
    }

    // MARK: Finder actions ("Keep Downloaded")

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let keep = actionIdentifier.rawValue == "com.romulas.fsdrive.action.keep"
        for id in itemIdentifiers { Pinned.set(id, pinned: keep) }
        guard let manager else {
            completionHandler(NSFileProviderError(.providerNotFound))
            return Progress()
        }
        manager.signalEnumerator(for: .workingSet) { error in completionHandler(error) }
        return Progress()
    }
}
