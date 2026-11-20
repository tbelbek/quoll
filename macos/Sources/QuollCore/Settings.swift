import Foundation

public struct WebSettings: Codable, Sendable {
    public var enabled: Bool
    public var port: Int
    public var username: String
    public var password: String
    public var root: String?

    public init(
        enabled: Bool = false,
        port: Int = 8484,
        username: String = "",
        password: String = "",
        root: String? = nil
    ) {
        self.enabled = enabled
        self.port = port
        self.username = username
        self.password = password
        self.root = root
    }
}

public struct Preferences: Codable, Sendable {
    public var roots: [String]
    public var excludes: [String]
    /// Paths or names indexed even when an exclude (default or user) matches.
    public var includes: [String]
    public var dataDirectory: String
    public var controlPath: String
    public var http: WebSettings
    public var defaultLimit: Int
    public var skipHidden: Bool
    public var skipPackages: Bool
    public var followSymlinks: Bool
    /// Apply `ExcludeRules.defaults` on top of `excludes`.
    public var useDefaultExcludes: Bool

    public init(
        roots: [String],
        excludes: [String] = [],
        includes: [String] = [],
        dataDirectory: String,
        controlPath: String,
        http: WebSettings = WebSettings(),
        defaultLimit: Int = 100,
        skipHidden: Bool = false,
        skipPackages: Bool = false,
        followSymlinks: Bool = false,
        useDefaultExcludes: Bool = true
    ) {
        self.roots = roots
        self.excludes = excludes
        self.includes = includes
        self.dataDirectory = dataDirectory
        self.controlPath = controlPath
        self.http = http
        self.defaultLimit = defaultLimit
        self.skipHidden = skipHidden
        self.skipPackages = skipPackages
        self.followSymlinks = followSymlinks
        self.useDefaultExcludes = useDefaultExcludes
    }

    private enum CodingKeys: String, CodingKey {
        case roots, excludes, includes, dataDirectory, controlPath, http, defaultLimit
        case skipHidden, skipPackages, followSymlinks, useDefaultExcludes
    }

    // Tolerant decoding: settings files written by older versions lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preferences.default()
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? fallback.roots
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        includes = try c.decodeIfPresent([String].self, forKey: .includes) ?? []
        dataDirectory = try c.decodeIfPresent(String.self, forKey: .dataDirectory) ?? fallback.dataDirectory
        controlPath = try c.decodeIfPresent(String.self, forKey: .controlPath) ?? ""
        http = try c.decodeIfPresent(WebSettings.self, forKey: .http) ?? WebSettings()
        defaultLimit = try c.decodeIfPresent(Int.self, forKey: .defaultLimit) ?? 100
        skipHidden = try c.decodeIfPresent(Bool.self, forKey: .skipHidden) ?? false
        skipPackages = try c.decodeIfPresent(Bool.self, forKey: .skipPackages) ?? false
        followSymlinks = try c.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? false
        useDefaultExcludes = try c.decodeIfPresent(Bool.self, forKey: .useDefaultExcludes) ?? true
    }

    /// Effective exclude rules: user rules, shipped defaults, and Quoll's own data
    /// directory (indexing it would make every catalog save re-trigger the watcher).
    public var excludeRules: ExcludeRules {
        ExcludeRules(
            (useDefaultExcludes ? ExcludeRules.defaults : []) + excludes,
            includes: includes,
            alwaysExcluded: [dataDirectory]
        )
    }

    public static func defaultDataDirectory() -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Quoll", isDirectory: true).path
    }

    public static func `default`() -> Preferences {
        let home = NSHomeDirectory()
        var roots = [home]
        let applications = "/Applications"
        if FileManager.default.fileExists(atPath: applications), !roots.contains(applications) {
            roots.append(applications)
        }
        let data = defaultDataDirectory()
        return Preferences(
            roots: roots,
            dataDirectory: data,
            controlPath: (data as NSString).appendingPathComponent("quoll.sock")
        )
    }

    public static func load(dataDirectory: String? = nil) throws -> Preferences {
        let directory = dataDirectory ?? Preferences.defaultDataDirectory()
        let path = (directory as NSString).appendingPathComponent("settings.json")
        let url = URL(fileURLWithPath: path)

        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var settings = try decoder.decode(Preferences.self, from: data)
            if let override = dataDirectory {
                settings.dataDirectory = override
            }
            if settings.controlPath.isEmpty {
                settings.controlPath = (settings.dataDirectory as NSString).appendingPathComponent("quoll.sock")
            }
            return settings
        }

        var settings = Preferences.default()
        if let override = dataDirectory {
            settings.dataDirectory = override
            settings.controlPath = (override as NSString).appendingPathComponent("quoll.sock")
        }
        try settings.save()
        return settings
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            atPath: dataDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let path = (dataDirectory as NSString).appendingPathComponent("settings.json")
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public var catalogURL: URL {
        URL(fileURLWithPath: (dataDirectory as NSString).appendingPathComponent("catalog.json"))
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            atPath: dataDirectory,
            withIntermediateDirectories: true
        )
        let socketDirectory = (controlPath as NSString).deletingLastPathComponent
        if !socketDirectory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: socketDirectory,
                withIntermediateDirectories: true
            )
        }
    }
}
