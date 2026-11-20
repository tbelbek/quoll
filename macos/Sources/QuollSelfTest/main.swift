import Foundation
import QuollCore

ScanHelper.runIfRequested()

if CommandLine.arguments.contains("--bench") {
    exit(runBench(CommandLine.arguments))
}
if CommandLine.arguments.contains("--volumes") {
    exit(runVolumes(CommandLine.arguments))
}
if CommandLine.arguments.contains("--m4") {
    exit(runDurability(CommandLine.arguments))
}
if CommandLine.arguments.contains("--equiv") {
    exit(runEquivalence(CommandLine.arguments))
}

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
expect(matches("ending:jpg;png;heic", entry("/tmp/a.PNG")), "ending: list")
expect(!matches("ending:jpg;png", entry("/tmp/a.gif")), "ending: list rejects")
expect(SearchParser.parse("body:needle").warnings.contains { $0.contains("body:") }, "unsupported filter warning")

// Dates name whole periods
func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}
expect(matches("changed:2025", entry("/tmp/a", modified: at(2025, 7, 1))), "date: year is the whole year")
expect(!matches("changed:2025", entry("/tmp/a", modified: at(2026, 1, 1, 0))), "date: year ends at its end")
expect(matches("changed:2025-06", entry("/tmp/a", modified: at(2025, 6, 30, 23))), "date: month is the whole month")
expect(matches("changed:>2025", entry("/tmp/a", modified: at(2026, 1, 1, 0))), "date: > means after the period")
expect(!matches("changed:>2025", entry("/tmp/a", modified: at(2025, 12, 31, 23))), "date: > excludes the period")
expect(matches("changed:<=2025-06", entry("/tmp/a", modified: at(2025, 6, 30, 23))), "date: <= includes the period")
expect(!matches("changed:<2025-06", entry("/tmp/a", modified: at(2025, 6, 1, 1))), "date: < is before the period")
expect(matches("changed:2025-01-01..2025-06-30", entry("/tmp/a", modified: at(2025, 6, 30, 18))), "date: range includes its last day")
expect(matches("changed:today", entry("/tmp/a", modified: Date())), "date: today")

// Fixtures: build a real folder tree, scan it into a snapshot, map it.
func makeTree(_ files: [String: Int], dirs: [String] = []) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qt-" + UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for dir in dirs { try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
    for (file, size) in files {
        let url = root.appendingPathComponent(file)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 120, count: size).write(to: url)
    }
    return root.standardizedFileURL.path
}

func scanStore(_ root: String, settings: Preferences? = nil) throws -> IndexStore {
    var prefs = settings ?? Preferences.default()
    if settings == nil { prefs.dataDirectory = root + "/.quoll-data" }
    let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("qs-" + UUID().uuidString).path
    _ = try IndexStore.scan(roots: [root], rules: prefs.excludeRules, into: snapshot, meta: SnapshotMeta())
    let store = IndexStore()
    try store.write { try store.adopt(directory: snapshot) }
    return store
}

func allPaths(_ store: IndexStore) -> Set<String> {
    store.read { Set((0..<store.count).filter { !store.isDead($0) }.map { store.path($0) }) }
}

func setModified(_ path: String, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
}

let engine = QueryEngine()
func names(_ query: String, _ store: IndexStore, sort: SortKey = .name, ascending: Bool = true, limit: Int = 100) -> [String] {
    engine.search(QueryOptions(query: query, limit: limit, sort: sort, ascending: ascending), in: store).results.map(\.name)
}

// Search engine basics
do {
    let root = try makeTree(["b.txt": 2, "a.txt": 1, "Notes.md": 5])
    defer { try? FileManager.default.removeItem(atPath: root) }
    try setModified(root + "/a.txt", 1_000_000)
    try setModified(root + "/b.txt", 2_000_000)
    let store = try scanStore(root)
    let page = engine.search(QueryOptions(query: "ending:txt", limit: 1, sort: .name, ascending: true), in: store)
    expect(page.total == 2, "search total")
    expect(page.count == 1, "search limit")
    expect(page.results.first?.name == "a.txt", "search sort")
    expect(page.truncated, "search truncated flag")
    expect(names("", store, sort: .modified, ascending: false).first == "Notes.md", "newest first")
    expect(names("ending:txt", store, sort: .modified, ascending: false) == ["b.txt", "a.txt"], "sort by modified")
    expect(names("notes", store) == ["Notes.md"], "fast path substring")
    expect(names("matchcase:notes", store).isEmpty && names("matchcase:Notes", store) == ["Notes.md"], "matchcase")
} catch {
    expect(false, "search fixture: \(error)")
}

// Folding: Turkish dotted/dotless i and diacritics, both directions
do {
    let root = try makeTree(["ırmak.txt": 1, "İSTANBUL.pdf": 1, "Café.md": 1, "plain.txt": 1])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try scanStore(root)
    expect(names("irmak", store) == ["ırmak.txt"], "fold: irmak finds ırmak")
    expect(names("istanbul", store) == ["İSTANBUL.pdf"], "fold: istanbul finds İSTANBUL")
    expect(names("IRMAK", store) == ["ırmak.txt"], "fold: upper-case query")
    expect(names("cafe", store) == ["Café.md"], "fold: diacritic")
    expect(names("caf*", store) == ["Café.md"], "fold: wildcard")
} catch {
    expect(false, "fold fixture: \(error)")
}

// Snapshot round trip, resolve, children order
do {
    let root = try makeTree(["sub/c.txt": 1, "a.txt": 1, "b.md": 1])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try scanStore(root)
    let dir = store.snapshotDirectory!
    let again = IndexStore()
    try again.write { try again.adopt(directory: dir) }
    expect(allPaths(again) == allPaths(store), "snapshot round trip")
    expect(again.read { again.resolve(root + "/sub/c.txt").map { again.path($0) } } == root + "/sub/c.txt", "resolve path")
    expect(again.read { again.liveFiles } == 3 && again.read { again.liveFolders } == 2, "live counters")
} catch {
    expect(false, "snapshot fixture: \(error)")
}

// Scanner and excludes
do {
    let root = try makeTree(["a.txt": 1, "b.md": 1, "sub/c.txt": 1])
    defer { try? FileManager.default.removeItem(atPath: root) }
    var settings = Preferences.default()
    settings.dataDirectory = root + "/.quoll-data"
    settings.excludes = ["*.md"]
    let paths = allPaths(try scanStore(root, settings: settings))
    expect(paths.contains(root + "/a.txt"), "scanner file")
    expect(paths.contains(root + "/sub/c.txt"), "scanner nested file")
    expect(paths.contains(root + "/sub"), "scanner directory")
    expect(!paths.contains(root + "/b.md"), "scanner exclude")
} catch {
    expect(false, "scanner fixture: \(error)")
}

// Excludes: name rules prune whole subtrees, includes override, data dir is hard
do {
    let base = try makeTree(["node_modules/a/b.js": 1, "keep/node_modules/x/y.js": 1, "cache/inner/deep/z.txt": 1,
                             "cache/other.txt": 1, "data/catalog.json": 1, "top.txt": 1])
    defer { try? FileManager.default.removeItem(atPath: base) }
    var settings = Preferences.default()
    settings.dataDirectory = base + "/data"
    settings.excludes = [base + "/cache"]
    let paths = allPaths(try scanStore(base, settings: settings))
    expect(paths.contains(base + "/top.txt"), "exclude: normal file kept")
    expect(!paths.contains(base + "/node_modules"), "exclude: default name rule")
    expect(!paths.contains(base + "/node_modules/a/b.js"), "exclude: subtree of name rule")
    expect(!paths.contains(base + "/keep/node_modules/x/y.js"), "exclude: name rule matches at any depth")
    expect(!paths.contains(base + "/cache/other.txt"), "exclude: path rule")
    expect(!paths.contains(base + "/data/catalog.json"), "exclude: data directory is hard-excluded")

    settings.includes = ["node_modules", base + "/cache/inner", base + "/data"]
    let included = allPaths(try scanStore(base, settings: settings))
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

// Scopes, opened sort, folder totals
do {
    let root = try makeTree(["docs/a.md": 10, "docs/b.md": 20, ".hidden/c.md": 5, "Library/d.md": 1, "x.txt": 1])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try scanStore(root)
    let scoped = engine.search(QueryOptions(query: "scope:notes", limit: 10), in: store)
    expect(scoped.total == 0 && scoped.warnings.contains { $0.contains("unknown scope") }, "scope: unknown is reported")
    engine.setScopes(["notes": "under:docs ending:md"])
    expect(Set(names("scope:notes", store)) == ["a.md", "b.md"], "scope: expands to its query")
    expect(Set(names("scope:notes b", store)) == ["b.md"], "scope: combines with words")
    engine.setScopes(Preferences.builtInScopes)
    let expanded = SearchParser.expandScopes("scope:user x", Preferences.builtInScopes).query
    expect(expanded.hasPrefix("(under:~"), "scope:user is built in")
    let counts = [root + "/docs/b.md": 3, root + "/x.txt": 1]
    let opened = engine.search(QueryOptions(query: "", limit: 3, sort: .opened, ascending: false), in: store, openCounts: counts)
    expect(opened.results.first?.name == "b.md" && opened.results.first?.openCount == 3, "opened: most opened first")
    expect(opened.results.dropFirst().first?.name == "x.txt", "opened: then the next most opened")
    let totals = store.read { store.subtreeTotals(store.resolve(root + "/docs")!) }
    expect(totals.bytes == 30 && totals.files == 2, "folder totals")
} catch {
    expect(false, "scope fixture: \(error)")
}

// Overlay: subtree delete and rename cost, compaction keeps the live view
do {
    let root = try makeTree(["big/.keep": 1, "other/file.txt": 1])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try scanStore(root)
    let big = store.read { store.resolve(root + "/big")! }
    let other = store.read { store.resolve(root + "/other")! }
    store.write {
        for i in 0..<100_000 {
            let raw = Array("f\(i).txt".utf8)
            raw.withUnsafeBufferPointer { r in
                store.appendDelta(parent: big, raw: r, folded: r, flags: 0, meta: EntryMeta(mtime: 1, ctime: 1, size: 1), inode: 0)
            }
        }
    }
    expect(engine.search(QueryOptions(query: "f9999", limit: 5), in: store).total == 11, "overlay entries searchable")

    let renameStart = Date()
    store.write {
        let raw = Array("renamed".utf8)
        raw.withUnsafeBufferPointer { store.move(big, to: other, raw: $0, folded: $0) }
    }
    let renameMS = Date().timeIntervalSince(renameStart) * 1000
    expect(store.read { store.resolve(root + "/other/renamed/f42.txt") } != nil, "move keeps subtree reachable")
    expect(renameMS < 5, "move is O(1) (\(String(format: "%.3f", renameMS)) ms)")

    let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("qc-" + UUID().uuidString).path
    let before = allPaths(store)
    try store.read { try store.writeSnapshot(to: snapshot, meta: store.meta) }
    try store.write { try store.adopt(directory: snapshot) }
    expect(allPaths(store) == before, "compaction preserves the live tree")
    expect(store.read { store.pendingChanges } == 0, "compaction clears the overlay")

    let renamed = store.read { store.resolve(root + "/other/renamed")! }
    let deleteStart = Date()
    store.write { store.removeSubtree(renamed) }
    let deleteMS = Date().timeIntervalSince(deleteStart) * 1000
    expect(store.read { store.resolve(root + "/other/renamed/f1.txt") } == nil, "subtree delete")
    expect(deleteMS < 50, "100k-entry subtree delete (\(String(format: "%.1f", deleteMS)) ms)")
} catch {
    expect(false, "overlay fixture: \(error)")
}

// under:/parent: take folder names or absolute paths
do {
    let root = try makeTree(["src/a.swift": 1, "proj/src/b.swift": 1, "proj/docs/c.md": 1])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try scanStore(root)
    expect(Set(names("under:src ending:swift", store)) == ["a.swift", "b.swift"], "under: folder name")
    expect(names("under:\(root)/proj ending:swift", store) == ["b.swift"], "under: absolute path")
    expect(Set(names("parent:src", store)) == ["a.swift", "b.swift"], "parent: folder name")
    expect(Set(names("path:proj/docs", store)) == ["c.md", "docs"], "path: fragment across folders")
} catch {
    expect(false, "under fixture: \(error)")
}

// Old settings files (no includes/useDefaultExcludes keys) still decode
do {
    let json = #"{"roots":["/tmp"],"excludes":[],"dataDirectory":"/tmp/q","controlPath":"/tmp/q/s","http":{"enabled":false,"port":8484,"username":"","password":""},"defaultLimit":100,"skipHidden":false,"skipPackages":false,"followSymlinks":false}"#
    let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    expect(decoded.useDefaultExcludes && decoded.includes.isEmpty, "settings: tolerant decoding")
} catch {
    expect(false, "settings decode: \(error)")
}

// Result pager: bounded page cache, stale replies dropped
do {
    var deferred: [(QueryOptions, (QueryResult?) -> Void)] = []
    func page(_ o: QueryOptions) -> QueryResult {
        let rows = (o.offset..<min(o.offset + o.limit, 5_000)).map { entry("/tmp/r\($0)") }
        return QueryResult(query: o.query, count: rows.count, total: 5_000, tookMS: 1, truncated: true, results: rows)
    }
    let pager = ResultPager(pageSize: 200, cap: 10_000, maxPages: 3) { options, _, _, reply in
        deferred.append((options, reply))
    }
    pager.search("old", sort: .modified, ascending: false)
    let stale = deferred.removeFirst()
    pager.search("new", sort: .modified, ascending: false)
    stale.1(page(stale.0))
    expect(pager.total == 0, "pager: stale reply dropped")
    let fresh = deferred.removeFirst()
    fresh.1(page(fresh.0))
    expect(pager.total == 5_000 && pager.rowCount == 5_000, "pager: current reply accepted")
    for row in stride(from: 0, to: 5_000, by: 150) {
        _ = pager.entry(at: row)
        while !deferred.isEmpty { let (o, reply) = deferred.removeFirst(); reply(page(o)) }
        expect(pager.cachedPages <= 3, "pager: at most 3 pages cached (row \(row))")
    }
    expect(pager.entry(at: 4_999)?.path == "/tmp/r4999", "pager: row maps to its entry")
    pager.dropCache()
    expect(pager.cachedPages == 0, "pager: hide drops the cache")
}

// IPC round trip
do {
    let root = try makeTree(["control.txt": 1])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let controlStore = try scanStore(root)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("test.sock").path

    let server = ControlServer(controlPath: socket) { request in
        if request.command == "search" {
            let response = engine.search(
                QueryOptions(query: request.query ?? "", limit: 10, sort: .name, ascending: true),
                in: controlStore
            )
            return ControlReply(id: request.id, count: response.count, total: response.total, results: response.results)
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
