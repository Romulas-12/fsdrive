import FileProvider
import UniformTypeIdentifiers
import FSDriveCore

/// One Finder item: the domain root, a library (top-level folder) or a file/folder
/// inside a library.
final class Item: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let capabilities: NSFileProviderItemCapabilities
    let contentPolicy: NSFileProviderContentPolicy
    let isPinned: Bool
    /// Server-side path inside the library, for path-based API calls.
    let path: String?
    let versionId: Int64?

    private init(id: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, filename: String, isFolder: Bool,
                 size: Int64?, mtimeNs: Int64?, contentVersion: String, metadataVersion: String,
                 capabilities: NSFileProviderItemCapabilities, path: String?, versionId: Int64?) {
        itemIdentifier = id
        parentItemIdentifier = parent
        self.filename = filename
        contentType = isFolder ? .folder : (UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data)
        documentSize = size.map { NSNumber(value: $0) }
        contentModificationDate = mtimeNs.map { Date(timeIntervalSince1970: Double($0) / 1e9) }
        isPinned = Pinned.load().contains(id.rawValue)
        itemVersion = NSFileProviderItemVersion(contentVersion: Data(contentVersion.utf8),
                                                metadataVersion: Data("\(metadataVersion)|\(isPinned)".utf8))
        self.capabilities = capabilities
        contentPolicy = isPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
        self.path = path
        self.versionId = versionId
    }

    /// Read by the Finder menu rules for the "Keep Downloaded" actions (Info.plist).
    var userInfo: [AnyHashable: Any]? { ["pinned": isPinned ? "1" : "0"] }

    static let folderCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting, .allowsDeleting,
    ]
    static let fileCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting,
    ]

    static var root: Item {
        Item(id: .rootContainer, parent: .rootContainer, filename: "FSDrive", isFolder: true, size: nil, mtimeNs: nil,
             contentVersion: "root", metadataVersion: "root", capabilities: [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems],
             path: nil, versionId: nil)
    }

    /// A library shows up as a top-level folder. Renaming or deleting a whole library
    /// from Finder is not supported yet.
    convenience init(library: LibraryDTO) {
        self.init(id: ItemID.library(library.id).identifier, parent: .rootContainer, filename: library.name, isFolder: true,
                  size: nil, mtimeNs: Int64(Date().timeIntervalSince1970 * 1e9), contentVersion: "lib", metadataVersion: library.name,
                  capabilities: [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems], path: nil, versionId: nil)
    }

    convenience init(lib: Int64, node: NodeDTO) {
        self.init(lib: lib, fileId: node.fileId, kind: node.kind, path: node.path, parentId: node.parentId, versionId: node.versionId,
                  size: node.size, mtimeNs: node.mtimeNs)
    }

    convenience init(lib: Int64, change c: ChangeDTO) {
        self.init(lib: lib, fileId: c.fileId, kind: c.kind, path: c.path, parentId: c.parentId, versionId: c.versionId,
                  size: c.size, mtimeNs: c.mtimeNs)
    }

    convenience init(lib: Int64, fileId: Int64, kind: NodeKind, path: String, parentId: Int64?, versionId: Int64?, size: Int64?, mtimeNs: Int64?) {
        // The user's personal library is the FSDrive root in Finder.
        let parent = parentId.map { ItemID.node(lib: lib, id: $0) } ?? .root
        let isFolder = kind == .dir
        self.init(id: ItemID.node(lib: lib, id: fileId).identifier, parent: parent.identifier, filename: VPath.name(path), isFolder: isFolder,
                  size: isFolder ? nil : size, mtimeNs: mtimeNs,
                  contentVersion: isFolder ? "dir" : "v\(versionId ?? 0)",
                  metadataVersion: "\(path)|\(mtimeNs ?? 0)|\(versionId ?? 0)",
                  capabilities: isFolder ? Item.folderCapabilities : Item.fileCapabilities, path: path, versionId: versionId)
    }
}

extension NSFileProviderItemVersion {
    /// The server version this Finder copy was based on ("v<id>").
    var serverVersionId: Int64? {
        let s = String(decoding: contentVersion, as: UTF8.self)
        return s.hasPrefix("v") ? Int64(s.dropFirst()) : nil
    }
}
