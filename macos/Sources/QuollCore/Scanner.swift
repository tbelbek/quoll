import Foundation

/// Path helpers kept from the 1.0 scanner (the walker itself is `BulkScanner`).
public enum Scanner {
    public static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }
}
