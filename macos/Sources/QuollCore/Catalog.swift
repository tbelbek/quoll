import Foundation

/// Thread-safe in-memory index with a JSON archive on disk.
public final class Catalog {
    private let lock = NSLock()
    private var entriesByPath: [String: FileEntry] = [:]
    private(set) public var lastScan: Date?
    private(set) public var roots: [String] = []

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesByPath.count
    }

    public var fileTotal: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesByPath.values.reduce(into: 0) { $0 += $1.isDirectory ? 0 : 1 }
    }

    public var folderTotal: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesByPath.values.reduce(into: 0) { $0 += $1.isDirectory ? 1 : 0 }
    }

    public func allEntries() -> [FileEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entriesByPath.values)
    }

    public func entry(at path: String) -> FileEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entriesByPath[path]
    }

    public func replaceAll(with entries: [FileEntry], roots: [String]) {
        lock.lock()
        entriesByPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        lastScan = Date()
        self.roots = roots
        lock.unlock()
    }

    public func put(_ entry: FileEntry) {
        lock.lock()
        entriesByPath[entry.path] = entry
        lock.unlock()
    }

    public func insert(contentsOf entries: [FileEntry]) {
        lock.lock()
        for entry in entries {
            entriesByPath[entry.path] = entry
        }
        lock.unlock()
    }

    public func remove(path: String) {
        lock.lock()
        entriesByPath.removeValue(forKey: path)
        lock.unlock()
    }

    public func removeBranch(path: String) {
        lock.lock()
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in entriesByPath.keys where key == path || key.hasPrefix(prefix) {
            entriesByPath.removeValue(forKey: key)
        }
        lock.unlock()
    }

    public func removeAll(under root: String) {
        removeBranch(path: root)
    }

    public func markScanned() {
        lock.lock()
        lastScan = Date()
        lock.unlock()
    }

    // MARK: - Archive

    public func save(to url: URL) throws {
        let archive = Archive(
            version: 1,
            roots: roots,
            lastScan: lastScan,
            entries: allEntries()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        try data.write(to: url, options: .atomic)
    }

    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: data)
        lock.lock()
        entriesByPath = Dictionary(
            archive.entries.map { ($0.path, $0) },
            uniquingKeysWith: { _, last in last }
        )
        roots = archive.roots
        lastScan = archive.lastScan
        lock.unlock()
    }

    private struct Archive: Codable {
        var version: Int
        var roots: [String]
        var lastScan: Date?
        var entries: [FileEntry]
    }
}
