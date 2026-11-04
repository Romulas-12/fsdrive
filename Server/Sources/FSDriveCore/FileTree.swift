import Foundation

public enum FileTree {
    /// Lists files and folders, parents before children, with NFC library-relative paths.
    public static func walk(_ dir: String) throws -> [(String, StatInfo)] {
        var result = [(String, StatInfo)]()
        guard let e = FileManager.default.enumerator(atPath: dir) else { return result }
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if VPath.isIgnored(name: name) {
                e.skipDescendants()
                continue
            }
            guard let st = FileIO.lstat(dir + "/" + rel), st.kind == .file || st.kind == .dir,
                  let path = try? VPath.normalize(rel) else { continue }
            result.append((path, st))
        }
        result.sort { $0.0 < $1.0 }
        return result
    }
}
