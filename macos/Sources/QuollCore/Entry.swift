import Foundation

/// One scanned file or directory.
public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var created: Date
    public var accessed: Date
    public var fileExtension: String
    public var level: Int
    public var mount: String

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modified: Date,
        created: Date,
        accessed: Date,
        fileExtension: String,
        level: Int,
        mount: String
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
        self.accessed = accessed
        self.fileExtension = fileExtension
        self.level = level
        self.mount = mount
    }

    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentAccessDateKey,
            .isSymbolicLinkKey
        ])

        let standardized = url.standardizedFileURL
        self.path = standardized.path
        self.name = standardized.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.size = Int64(values.fileSize ?? 0)
        self.modified = values.contentModificationDate ?? .distantPast
        self.created = values.creationDate ?? .distantPast
        self.accessed = values.contentAccessDate ?? .distantPast
        self.fileExtension = standardized.pathExtension.lowercased()
        self.level = max(0, standardized.pathComponents.count - 1)
        let components = standardized.pathComponents
        if components.count > 2, components[1] == "Volumes" {
            self.mount = "/Volumes/\(components[2])"
        } else {
            self.mount = "/"
        }
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Size rendered the way Quoll renders it by default (bytes).
    public var formattedSize: String {
        if isDirectory { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name
    case path
    case size
    case modified
    case created
    case accessed
    case fileExtension
    case level
}

public struct QueryOptions: Codable, Sendable {
    public var query: String
    public var limit: Int
    public var offset: Int
    public var sort: SortKey
    public var ascending: Bool
    public var includeDirectories: Bool
    public var includeFiles: Bool

    public init(
        query: String,
        limit: Int = 100,
        offset: Int = 0,
        sort: SortKey = .name,
        ascending: Bool = true,
        includeDirectories: Bool = true,
        includeFiles: Bool = true
    ) {
        self.query = query
        self.limit = limit
        self.offset = offset
        self.sort = sort
        self.ascending = ascending
        self.includeDirectories = includeDirectories
        self.includeFiles = includeFiles
    }
}

public struct QueryResult: Codable, Sendable {
    public var query: String
    public var count: Int
    public var total: Int
    public var tookMS: Double
    public var truncated: Bool
    public var results: [FileEntry]
    public var warnings: [String] = []

    public init(
        query: String,
        count: Int,
        total: Int,
        tookMS: Double,
        truncated: Bool,
        results: [FileEntry]
    ) {
        self.query = query
        self.count = count
        self.total = total
        self.tookMS = tookMS
        self.truncated = truncated
        self.results = results
    }
}

public struct CatalogStatus: Codable, Sendable {
    public var files: Int
    public var directories: Int
    public var roots: [String]
    public var lastScan: Date?
    public var catalogBytes: Int64
    public var controlPath: String
    public var uptime: Double

    public init(
        files: Int,
        directories: Int,
        roots: [String],
        lastScan: Date?,
        catalogBytes: Int64,
        controlPath: String,
        uptime: Double
    ) {
        self.files = files
        self.directories = directories
        self.roots = roots
        self.lastScan = lastScan
        self.catalogBytes = catalogBytes
        self.controlPath = controlPath
        self.uptime = uptime
    }
}
