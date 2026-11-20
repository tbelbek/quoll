import Foundation
import QuollCore

var failures = 0

func expect(_ condition: Bool, _ name: String) {
    if condition {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

func entry(
    _ path: String,
    size: Int64 = 100,
    isDirectory: Bool = false,
    modified: Date = Date()
) -> FileEntry {
    let name = (path as NSString).lastPathComponent
    let fileExtension = (path as NSString).pathExtension.lowercased()
    return FileEntry(
        path: path,
        name: name,
        isDirectory: isDirectory,
        size: size,
        modified: modified,
        created: modified,
        accessed: modified,
        fileExtension: fileExtension,
        level: max(0, path.split(separator: "/").count - 1),
        mount: "/"
    )
}

func matches(_ query: String, _ file: FileEntry) -> Bool {
    Matcher(query: SearchParser.parse(query)).matches(file)
}

// Query parser
expect(matches("package", entry("/tmp/Package.swift")), "substring match")
expect(!matches("package", entry("/tmp/README.md")), "substring miss")
expect(matches("ending:swift package", entry("/tmp/Package.swift")), "AND + ending")
expect(!matches("ending:swift package", entry("/tmp/README.md")), "AND rejects")
expect(matches("ending:swift|ending:md", entry("/tmp/README.md")), "OR")
expect(!matches("ending:swift|ending:md", entry("/tmp/photo.png")), "OR rejects")
expect(!matches("!ending:md", entry("/tmp/README.md")), "NOT")
expect(matches("!ending:md", entry("/tmp/Package.swift")), "NOT passes")
expect(matches("*.swift", entry("/tmp/Package.swift")), "wildcard")
expect(!matches("*.swift", entry("/tmp/README.md")), "wildcard rejects")
expect(matches("Pack?ge*", entry("/tmp/Package.swift")), "single-char wildcard")
expect(matches("bytes:>1kb", entry("/tmp/big.bin", size: 2048)), "bytes greater")
expect(!matches("bytes:>1kb", entry("/tmp/small.bin", size: 100)), "bytes greater rejects")
expect(matches("bytes:1kb..2kb", entry("/tmp/mid.bin", size: 1500)), "bytes range")
expect(matches("changed:today", entry("/tmp/today.txt", modified: Date())), "changed today")
expect(!matches("changed:today", entry("/tmp/old.txt", modified: Date(timeIntervalSince1970: 0))), "changed today rejects")
expect(matches("path:src", entry("/tmp/src/main.swift")), "path filter")
expect(!matches("path:src", entry("/tmp/bin/main.swift")), "path rejects")
expect(matches("\"hello world\"", entry("/tmp/hello world.txt")), "quoted phrase")
expect(!matches("\"hello world\"", entry("/tmp/hello-world.txt")), "quoted phrase rejects")
expect(matches("pattern:^Package\\.swift$", entry("/tmp/Package.swift")), "pattern")
expect(!matches("pattern:^Package\\.swift$", entry("/tmp/PackageTests.swift")), "pattern rejects")
expect(matches("kind:folder", entry("/tmp/src", isDirectory: true)), "kind folder")
expect(!matches("kind:folder", entry("/tmp/src/main.swift")), "kind folder rejects")
expect(matches("kind:file", entry("/tmp/src/main.swift")), "kind file")
expect(!matches("matchcase:package", entry("/tmp/Package.swift")), "matchcase")
expect(matches("icase:package", entry("/tmp/Package.swift")), "icase")
expect(matches("starts:Pack", entry("/tmp/Package.swift")), "starts")
expect(!matches("starts:ackage", entry("/tmp/Package.swift")), "starts rejects")
expect(matches("ends:.swift", entry("/tmp/Package.swift")), "ends")
expect(SearchParser.parse("body:needle").warnings.contains { $0.contains("body:") }, "unsupported filter warning")

// Search engine
let catalog = Catalog()
catalog.replaceAll(with: [
    entry("/tmp/b.txt", size: 2, modified: Date(timeIntervalSince1970: 2)),
    entry("/tmp/a.txt", size: 1, modified: Date(timeIntervalSince1970: 1))
], roots: ["/tmp"])
let page = QueryEngine().search(
    QueryOptions(query: "ending:txt", limit: 1, sort: .name, ascending: true),
    in: catalog
)
expect(page.total == 2, "search total")
expect(page.count == 1, "search limit")
expect(page.results.first?.name == "a.txt", "search sort")
expect(page.truncated, "search truncated flag")

// Archive round trip
do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let catalog = Catalog()
    catalog.replaceAll(with: [entry("/tmp/a.txt")], roots: ["/tmp"])
    let url = directory.appendingPathComponent("catalog.json")
    try catalog.save(to: url)

    let loaded = Catalog()
    try loaded.load(from: url)
    expect(loaded.count == 1, "archive count")
    expect(loaded.entry(at: "/tmp/a.txt")?.name == "a.txt", "archive entry")
} catch {
    expect(false, "archive round trip: \(error)")
}

// Scanner and excludes
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("b".utf8).write(to: root.appendingPathComponent("b.md"))
    try Data("c".utf8).write(to: root.appendingPathComponent("sub/c.txt"))
    defer { try? FileManager.default.removeItem(at: root) }

    let result = Scanner().scan(
        roots: [root.path],
        options: Scanner.Options(excludes: ["*.md"])
    )
    let names = Set(result.entries.map(\.name))
    expect(names.contains("a.txt"), "scanner file")
    expect(names.contains("c.txt"), "scanner nested file")
    expect(names.contains("sub"), "scanner directory")
    expect(!names.contains("b.md"), "scanner exclude")
} catch {
    expect(false, "scanner fixture: \(error)")
}

// Excludes: name rules prune whole subtrees, includes override, data dir is hard
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    for dir in ["node_modules/a", "keep/node_modules/x", "cache/inner/deep", "data"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["node_modules/a/b.js", "keep/node_modules/x/y.js", "cache/inner/deep/z.txt",
                 "cache/other.txt", "data/catalog.json", "top.txt"] {
        try Data("x".utf8).write(to: root.appendingPathComponent(file))
    }
    defer { try? fm.removeItem(at: root) }
    let base = root.standardizedFileURL.path

    var settings = Preferences.default()
    settings.dataDirectory = base + "/data"
    settings.excludes = [base + "/cache"]
    let paths = Set(Scanner().scan(roots: [base], options: Scanner.Options(rules: settings.excludeRules))
        .entries.map(\.path))
    expect(paths.contains(base + "/top.txt"), "exclude: normal file kept")
    expect(!paths.contains(base + "/node_modules"), "exclude: default name rule")
    expect(!paths.contains(base + "/node_modules/a/b.js"), "exclude: subtree of name rule")
    expect(!paths.contains(base + "/keep/node_modules/x/y.js"), "exclude: name rule matches at any depth")
    expect(!paths.contains(base + "/cache/other.txt"), "exclude: path rule")
    expect(!paths.contains(base + "/data/catalog.json"), "exclude: data directory is hard-excluded")

    settings.includes = ["node_modules", base + "/cache/inner", base + "/data"]
    let included = Set(Scanner().scan(roots: [base], options: Scanner.Options(rules: settings.excludeRules))
        .entries.map(\.path))
    expect(included.contains(base + "/node_modules/a/b.js"), "include: name overrides default exclude")
    expect(included.contains(base + "/cache/inner/deep/z.txt"), "include: path under an excluded folder")
    expect(included.contains(base + "/cache"), "include: excluded parent is passed through")
    expect(!included.contains(base + "/cache/other.txt"), "include: siblings stay excluded")
    expect(!included.contains(base + "/data/catalog.json"), "include: cannot override the data directory")

    let rules = settings.excludeRules
    expect(!rules.excludesAnyComponent(of: base + "/cache/inner/deep/z.txt"), "watcher: include honoured")
    expect(rules.excludesAnyComponent(of: base + "/cache/other.txt"), "watcher: exclude honoured")
    expect(rules.excludesAnyComponent(of: base + "/data/catalog.json"), "watcher: data directory")
} catch {
    expect(false, "exclude fixture: \(error)")
}

// Old settings files (no includes/useDefaultExcludes keys) still decode
do {
    let json = #"{"roots":["/tmp"],"excludes":[],"dataDirectory":"/tmp/q","controlPath":"/tmp/q/s","http":{"enabled":false,"port":8484,"username":"","password":""},"defaultLimit":100,"skipHidden":false,"skipPackages":false,"followSymlinks":false}"#
    let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    expect(decoded.useDefaultExcludes && decoded.includes.isEmpty, "settings: tolerant decoding")
} catch {
    expect(false, "settings decode: \(error)")
}

// IPC round trip
do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("test.sock").path

    let controlStore = Catalog()
    controlStore.replaceAll(with: [entry("/tmp/control.txt")], roots: ["/tmp"])
    let server = ControlServer(controlPath: socket) { request in
        if request.command == "search" {
            let response = QueryEngine().search(
                QueryOptions(query: request.query ?? "", limit: 10, sort: .name, ascending: true),
                in: controlStore
            )
            return ControlReply(
                id: request.id,
                count: response.count,
                total: response.total,
                results: response.results
            )
        }
        return ControlReply(id: request.id, message: "pong")
    }
    try server.start()
    defer { server.stop() }

    let client = ControlClient(controlPath: socket)
    let ping = try client.send(ControlRequest(command: "ping"))
    expect(ping.ok && ping.message == "pong", "control ping")

    let reply = try client.send(ControlRequest(id: "1", command: "search", query: "control", limit: 10))
    expect(reply.ok && reply.total == 1, "control search")
} catch {
    expect(false, "control round trip: \(error)")
}

if failures == 0 {
    print("\nall checks passed")
    exit(0)
} else {
    print("\n\(failures) check(s) failed")
    exit(1)
}
