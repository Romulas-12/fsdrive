import Foundation

public struct PathError: Error, CustomStringConvertible {
    public let description: String
}

/// Library-relative paths: NFC, "/"-separated, no leading slash, no "." or "..".
public enum VPath {
    public static func normalize(_ raw: String) throws -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let parts = nfc.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { throw PathError(description: "empty path") }
        for p in parts {
            if p == "." || p == ".." { throw PathError(description: "invalid component in \(raw)") }
            if p.utf8.count > 255 { throw PathError(description: "name too long in \(raw)") }
            if p.contains("\0") { throw PathError(description: "NUL in \(raw)") }
        }
        return parts.joined(separator: "/")
    }

    /// Case-insensitive key: two paths with the same key cannot coexist, because they
    /// would collide on APFS/NTFS clients.
    public static func key(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: nil)
    }

    public static func parent(_ path: String) -> String? {
        guard let i = path.lastIndex(of: "/") else { return nil }
        return String(path[..<i])
    }

    public static func name(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: i)...])
    }

    public static func isInside(_ path: String, _ dir: String) -> Bool {
        path.hasPrefix(dir + "/")
    }

    /// Ancestors from the shallowest: "a/b/c" -> ["a", "a/b"].
    public static func ancestors(_ path: String) -> [String] {
        var result = [String]()
        var p = parent(path)
        while let cur = p {
            result.insert(cur, at: 0)
            p = parent(cur)
        }
        return result
    }

    /// macOS and editor byproducts that never sync.
    public static func isIgnored(name: String) -> Bool {
        if name == ".DS_Store" || name == "Icon\r" { return true }
        if name.hasPrefix("._") || name.hasPrefix(".fsdrive-") || name.hasPrefix("~$") { return true }
        if name.hasPrefix(".rimfile-") { return true }  // temp files of clients from before the rename
        return [".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100"].contains(name)
    }

    /// "dir/report.pdf" -> "dir/report (conflict, MacBook, 2026-10-23 14.05.12).pdf"
    public static func conflictPath(_ path: String, device: String, date: Date = Date()) -> String {
        let tag = " (conflict, \(device), \(localTime(date, "%Y-%m-%d %H.%M.%S")))"
        let name = self.name(path)
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let newName = ext.isEmpty ? stem + tag : "\(stem)\(tag).\(ext)"
        if let p = parent(path) { return p + "/" + newName }
        return newName
    }
}
