import Foundation

/// Path helpers kept from the 1.0 scanner (the walker itself is `BulkScanner`).
public enum Scanner {
    public static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }

    /// Canonical form of an existing root: symlinks resolved, on-disk letter case
    /// (FSEvents reports real paths, so a root typed as `~/repos` would never match).
    public static func canonical(_ path: String) -> String {
        let standardized = standardize(path)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(standardized, &buffer) != nil else { return standardized }
        return String(cString: buffer)
    }
}
