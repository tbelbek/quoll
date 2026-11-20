import Foundation

public struct ScanIssue: Codable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct ScanResult: Sendable {
    public var entries: [FileEntry]
    public var errors: [ScanIssue]
    public var duration: TimeInterval

    public init(entries: [FileEntry], errors: [ScanIssue], duration: TimeInterval) {
        self.entries = entries
        self.errors = errors
        self.duration = duration
    }
}

public final class Scanner {
    public struct Options {
        public var excludes: [String]
        public var skipHidden: Bool
        public var skipPackages: Bool
        public var followSymlinks: Bool

        public init(
            excludes: [String] = [],
            skipHidden: Bool = false,
            skipPackages: Bool = false,
            followSymlinks: Bool = false
        ) {
            self.excludes = excludes
            self.skipHidden = skipHidden
            self.skipPackages = skipPackages
            self.followSymlinks = followSymlinks
        }
    }

    private let fileManager = FileManager.default

    public init() {}

    public func scan(
        roots: [String],
        options: Options,
        progress: ((Int) -> Void)? = nil
    ) -> ScanResult {
        let started = Date()
        var entries: [FileEntry] = []
        var errors: [ScanIssue] = []
        var seen = Set<String>()
        let excludes = Self.normalizedExcludes(options.excludes)

        var enumerationOptions: FileManager.DirectoryEnumerationOptions = []
        if options.skipHidden {
            enumerationOptions.insert(.skipsHiddenFiles)
        }
        if options.skipPackages {
            enumerationOptions.insert(.skipsPackageDescendants)
        }

        for root in roots {
            let standardizedRoot = Self.standardize(root)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardizedRoot, isDirectory: &isDirectory) else {
                errors.append(ScanIssue(path: standardizedRoot, message: "path does not exist"))
                continue
            }
            guard isDirectory.boolValue else {
                if let entry = try? FileEntry(url: URL(fileURLWithPath: standardizedRoot)),
                   !Self.isExcluded(entry, excludes: excludes),
                   seen.insert(entry.path).inserted {
                    entries.append(entry)
                }
                continue
            }

            let rootURL = URL(fileURLWithPath: standardizedRoot, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .contentAccessDateKey,
                    .isSymbolicLinkKey
                ],
                options: enumerationOptions,
                errorHandler: { url, error in
                    errors.append(ScanIssue(path: url.path, message: error.localizedDescription))
                    return true
                }
            ) else {
                errors.append(ScanIssue(path: standardizedRoot, message: "unable to enumerate"))
                continue
            }

            for case let url as URL in enumerator {
                if !options.followSymlinks {
                    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if values?.isSymbolicLink == true { continue }
                }

                do {
                    let entry = try FileEntry(url: url)
                    if Self.isExcluded(entry, excludes: excludes) { continue }
                    if seen.insert(entry.path).inserted {
                        entries.append(entry)
                    }
                    if entries.count % 2_000 == 0 {
                        progress?(entries.count)
                    }
                } catch {
                    errors.append(ScanIssue(path: url.path, message: error.localizedDescription))
                }
            }
        }

        return ScanResult(
            entries: entries,
            errors: errors,
            duration: Date().timeIntervalSince(started)
        )
    }

    public static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func normalizedExcludes(_ excludes: [String]) -> [String] {
        excludes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { pattern in
                if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
                    return (pattern as NSString).expandingTildeInPath
                }
                return standardize(pattern)
            }
    }

    public static func isExcluded(_ entry: FileEntry, excludes: [String]) -> Bool {
        guard !excludes.isEmpty else { return false }

        for raw in excludes {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }

            // A plain directory path excludes the directory and its whole subtree.
            if !pattern.contains("*") && !pattern.contains("?") && !pattern.contains("[") {
                if entry.path == pattern || entry.path.hasPrefix(pattern + "/") {
                    return true
                }
                continue
            }

            if pattern.contains("/") {
                if fnmatch(pattern, entry.path, 0) == 0 { return true }
            } else {
                if fnmatch(pattern, entry.name, 0) == 0 { return true }
                if fnmatch("*\(pattern)*", entry.name, 0) == 0 { return true }
            }
        }
        return false
    }
}
