import Foundation

// Wire types shared by fsdrived and fsdrive. JSON over HTTP, version prefix /v1.

public struct LibraryDTO: Codable, Sendable {
    public var id: Int64
    public var name: String
    public var latestSeq: Int64

    public init(id: Int64, name: String, latestSeq: Int64) {
        self.id = id
        self.name = name
        self.latestSeq = latestSeq
    }
}

public struct CreateLibraryRequest: Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public enum NodeKind: String, Codable, Sendable {
    case file, dir
}

public enum ChangeOp: String, Codable, Sendable {
    /// File created or modified; `versionId` names the new content.
    case put
    case mkdir
    case delete
    case move
}

public struct ChangeDTO: Codable, Sendable {
    public var seq: Int64
    public var op: ChangeOp
    public var kind: NodeKind
    public var fileId: Int64
    public var path: String
    public var oldPath: String?
    public var versionId: Int64?
    public var size: Int64?
    public var mtimeNs: Int64?
    public var contentHash: String?
    public var device: String?
    /// Folder holding the item after the change; nil is the library root.
    public var parentId: Int64?

    public init(seq: Int64, op: ChangeOp, kind: NodeKind, fileId: Int64, path: String, oldPath: String? = nil,
                versionId: Int64? = nil, size: Int64? = nil, mtimeNs: Int64? = nil, contentHash: String? = nil,
                device: String? = nil, parentId: Int64? = nil) {
        self.parentId = parentId
        self.seq = seq
        self.op = op
        self.kind = kind
        self.fileId = fileId
        self.path = path
        self.oldPath = oldPath
        self.versionId = versionId
        self.size = size
        self.mtimeNs = mtimeNs
        self.contentHash = contentHash
        self.device = device
    }
}

public struct ChangesResponse: Codable, Sendable {
    public var changes: [ChangeDTO]
    public var latestSeq: Int64
    public var hasMore: Bool

    public init(changes: [ChangeDTO], latestSeq: Int64, hasMore: Bool) {
        self.changes = changes
        self.latestSeq = latestSeq
        self.hasMore = hasMore
    }
}

public struct NodeDTO: Codable, Sendable {
    public var fileId: Int64
    public var kind: NodeKind
    public var path: String
    public var versionId: Int64?
    public var size: Int64?
    public var mtimeNs: Int64?
    public var contentHash: String?
    /// nil is the library root.
    public var parentId: Int64?

    public init(fileId: Int64, kind: NodeKind, path: String, versionId: Int64?, size: Int64?, mtimeNs: Int64?, contentHash: String?,
                parentId: Int64? = nil) {
        self.parentId = parentId
        self.fileId = fileId
        self.kind = kind
        self.path = path
        self.versionId = versionId
        self.size = size
        self.mtimeNs = mtimeNs
        self.contentHash = contentHash
    }
}

public struct TreeResponse: Codable, Sendable {
    public var seq: Int64
    public var nodes: [NodeDTO]

    public init(seq: Int64, nodes: [NodeDTO]) {
        self.seq = seq
        self.nodes = nodes
    }
}

public struct ChunkDTO: Codable, Sendable {
    public var h: String
    public var l: Int

    public init(h: String, l: Int) {
        self.h = h
        self.l = l
    }
}

public struct ManifestResponse: Codable, Sendable {
    public var size: Int64
    public var contentHash: String
    public var chunks: [ChunkDTO]

    public init(size: Int64, contentHash: String, chunks: [ChunkDTO]) {
        self.size = size
        self.contentHash = contentHash
        self.chunks = chunks
    }
}

extension Manifest {
    public var dto: [ChunkDTO] { chunks.map { ChunkDTO(h: $0.hash.hex, l: $0.length) } }

    public init?(dto: [ChunkDTO]) {
        var chunks = [ChunkInfo]()
        chunks.reserveCapacity(dto.count)
        var offset: Int64 = 0
        for c in dto {
            guard let h = Data(hex: c.h), h.count == 32, c.l > 0, c.l <= Chunker.maxSize else { return nil }
            chunks.append(ChunkInfo(hash: h, offset: offset, length: c.l))
            offset += Int64(c.l)
        }
        self.init(chunks: chunks)
    }
}

public struct CreateUploadRequest: Codable, Sendable {
    public var path: String
    public var baseVersionId: Int64?
    public var mtimeNs: Int64
    public var contentHash: String
    public var chunks: [ChunkDTO]
    public var device: String

    public init(path: String, baseVersionId: Int64?, mtimeNs: Int64, contentHash: String, chunks: [ChunkDTO], device: String) {
        self.path = path
        self.baseVersionId = baseVersionId
        self.mtimeNs = mtimeNs
        self.contentHash = contentHash
        self.chunks = chunks
        self.device = device
    }
}

public struct CreateUploadResponse: Codable, Sendable {
    public var uploadId: String
    public var missing: [String]

    public init(uploadId: String, missing: [String]) {
        self.uploadId = uploadId
        self.missing = missing
    }
}

public struct CommitResponse: Codable, Sendable {
    /// "ok" or "missing" (re-upload `missing` chunks, then commit again).
    public var status: String
    public var missing: [String]?
    public var change: ChangeDTO?
    /// True when the server kept the upload under a conflict name; `change.path` has it.
    public var conflict: Bool

    public init(status: String, missing: [String]? = nil, change: ChangeDTO? = nil, conflict: Bool = false) {
        self.status = status
        self.missing = missing
        self.change = change
        self.conflict = conflict
    }
}

public struct OpRequest: Codable, Sendable {
    public var op: ChangeOp
    public var path: String
    public var newPath: String?
    /// For deleting a file: the version the client last saw. A mismatch is a conflict.
    public var baseVersionId: Int64?
    public var device: String
    /// For deleting a folder: also delete everything inside (moved to the server trash).
    public var recursive: Bool?

    public init(op: ChangeOp, path: String, newPath: String? = nil, baseVersionId: Int64? = nil, device: String, recursive: Bool? = nil) {
        self.recursive = recursive
        self.op = op
        self.path = path
        self.newPath = newPath
        self.baseVersionId = baseVersionId
        self.device = device
    }
}

public struct RangesRequest: Codable, Sendable {
    /// [offset, length] pairs; the response body is their bytes back to back.
    public var ranges: [[Int64]]

    public init(ranges: [[Int64]]) { self.ranges = ranges }
}

public struct ErrorResponse: Codable, Sendable {
    public var error: String
}

public struct LibrariesResponse: Codable, Sendable {
    public var libraries: [LibraryDTO]
    public init(libraries: [LibraryDTO]) { self.libraries = libraries }
}

public struct OpResponse: Codable, Sendable {
    /// nil when the operation was already in effect (e.g. mkdir of an existing folder).
    public var change: ChangeDTO?
    public init(change: ChangeDTO?) { self.change = change }
}

public struct LoginRequest: Codable, Sendable {
    /// QTS user name and password; checked by QTS, never stored by FSDrive.
    public var user: String
    public var password: String
    public var device: String

    public init(user: String, password: String, device: String) {
        self.user = user
        self.password = password
        self.device = device
    }
}

public struct LoginResponse: Codable, Sendable {
    /// Token for this device only; revocable on the QTS settings page.
    public var token: String
    public var user: String
    /// How to reach the server away from home, with this device's SSH key; nil when
    /// the admin has not enabled the external connection.
    public var external: ExternalAccess?

    public init(token: String, user: String, external: ExternalAccess? = nil) {
        self.token = token
        self.user = user
        self.external = external
    }
}

/// Away from home the client reaches the server only through an SSH tunnel to the
/// gateway, authenticated with a key made for this one device.
public struct ExternalAccess: Codable, Sendable, Equatable {
    /// Gateway as seen from the internet, e.g. files.example.com and 2222.
    public var host: String
    public var port: Int
    public var user: String
    /// The gateway's host key ("ssh-ed25519 AAAA..."), so the client connects only to it.
    public var hostKey: String
    /// Where the tunnel leads: the server in the home network, "10.0.0.2:8740".
    public var target: String
    /// The device's private key (OpenSSH format); sent once and never stored by the server.
    public var privateKey: String?

    public init(host: String, port: Int, user: String, hostKey: String, target: String, privateKey: String?) {
        self.host = host
        self.port = port
        self.user = user
        self.hostKey = hostKey
        self.target = target
        self.privateKey = privateKey
    }
}

/// Public (no token) description of where this server can be reached.
public struct ServerInfo: Codable, Sendable {
    public var version: String
    /// The server's own address in the home network, as reached by this request.
    public var localURL: String?
    /// True when the external connection (SSH through the gateway) is ready; devices
    /// signed in at home then ask for their key.
    public var external: Bool?
    /// Address through an internet-facing HTTPS reverse proxy, when that mode is on.
    public var publicURL: String?

    public init(version: String, localURL: String?, external: Bool?, publicURL: String? = nil) {
        self.version = version
        self.localURL = localURL
        self.external = external
        self.publicURL = publicURL
    }
}
