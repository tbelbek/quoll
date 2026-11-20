import Foundation
import QuollCore

/// `quoll-selftest --bench <root> [--threads N] [--no-default-excludes] [--queries]`
///
/// Prints one TSV block: scan time, entries, snapshot bytes, footprint, load time
/// and per-query p50/p95. The same output is the acceptance gate for every
/// roadmap milestone.
func runBench(_ arguments: [String]) -> Int32 {
    func value(_ flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    guard let root = value("--bench") else {
        print("usage: quoll-selftest --bench <root> [--threads N] [--no-default-excludes]")
        return 2
    }
    let threads = Int(value("--threads") ?? "") ?? BulkScanner.defaultThreads
    // --snapshot DIR: reuse (or create and keep) a snapshot, so queries and the
    // load footprint are measured in a process that did not scan.
    let kept = value("--snapshot")
    let data = kept.map { ($0 as NSString).deletingLastPathComponent }
        ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("quoll-bench-\(getpid())")
    defer { if kept == nil { try? FileManager.default.removeItem(atPath: data) } }

    var settings = Preferences.default()
    settings.dataDirectory = data
    settings.roots = [Scanner.standardize(root)]
    settings.useDefaultExcludes = !arguments.contains("--no-default-excludes")
    let rules = settings.excludeRules

    func row(_ key: String, _ value: String) { print("\(key)\t\(value)") }
    func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

    let snapshot = kept ?? (data as NSString).appendingPathComponent("index-bench")
    if kept != nil, FileManager.default.fileExists(atPath: snapshot + "/meta.json") {
        return benchLoad(snapshot, queries: arguments.contains("--queries"))
    }
    let before = Footprint.current()
    let stats: BulkScanner.Stats
    do {
        stats = try IndexStore.scan(roots: settings.roots, rules: rules, into: snapshot,
                                    meta: SnapshotMeta(), threads: threads)
    } catch {
        print("scan failed: \(error)")
        return 1
    }
    let afterScan = Footprint.current()
    _ = malloc_zone_pressure_relief(nil, 0)
    print("footprint_after_scan\t\(mb(afterScan.now))")
    print("footprint_after_scan_relief\t\(mb(Footprint.current().now))")
    let bytes = (try? FileManager.default.contentsOfDirectory(atPath: snapshot))?.reduce(0) { total, name in
        let attributes = try? FileManager.default.attributesOfItem(atPath: (snapshot as NSString).appendingPathComponent(name))
        return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
    } ?? 0

    row("root", settings.roots[0])
    row("threads", "\(threads)")
    row("entries", "\(stats.entries)")
    row("folders", "\(stats.folders)")
    row("unreadable", "\(stats.unreadable)")
    row("scan_s", String(format: "%.2f", stats.duration))
    row("scan_footprint_peak", mb(afterScan.peak - before.now))
    row("snapshot_bytes", mb(bytes))

    let store = IndexStore()
    let loadStart = Date()
    do {
        try store.write { try store.adopt(directory: snapshot) }
    } catch {
        print("load failed: \(error)")
        return 1
    }
    row("load_ms", String(format: "%.1f", Date().timeIntervalSince(loadStart) * 1000))
    let report = store.read { store.memoryReport }
    row("mapped", mb(report.mapped))
    row("overlay", mb(report.overlay))
    row("footprint_after_load", mb(Footprint.current().now))

    if arguments.contains("--queries") {
        benchQueries(store)
        row("footprint_after_queries", mb(Footprint.current().now))
    }
    return 0
}

func benchLoad(_ snapshot: String, queries: Bool) -> Int32 {
    func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    let start = Footprint.current().now
    let store = IndexStore()
    let loadStart = Date()
    do {
        try store.write { try store.adopt(directory: snapshot) }
    } catch {
        print("load failed: \(error)")
        return 1
    }
    print("entries\t\(store.count)")
    print("load_ms\t\(String(format: "%.1f", Date().timeIntervalSince(loadStart) * 1000))")
    print("footprint_process_start\t\(mb(start))")
    print("footprint_after_load\t\(mb(Footprint.current().now))")
    if CommandLine.arguments.contains("--compact") {
        let target = snapshot + "-compacted"
        defer { try? FileManager.default.removeItem(atPath: target) }
        let started = Date()
        do { try store.read { try store.writeSnapshot(to: target, meta: store.meta) } } catch { print("compact failed: \(error)") }
        print("compact_s\t\(String(format: "%.2f", Date().timeIntervalSince(started)))")
        print("footprint_peak_after_compact\t\(mb(Footprint.current().peak))")
        _ = malloc_zone_pressure_relief(nil, 0)
        print("footprint_after_compact\t\(mb(Footprint.current().now))")
    }
    if queries {
        benchQueries(store)
        print("footprint_after_queries\t\(mb(Footprint.current().now))")
        print("footprint_peak\t\(mb(Footprint.current().peak))")
    }
    return 0
}

/// Fixed query set; each query runs 20 times, p50/p95 in ms.
func benchQueries(_ store: IndexStore) {
    let engine = QueryEngine()
    let queries = ["", "kanelbulle", "*.md", "ending:md", "path:.config json", "report draft", "README",
                   "path:Repos/quoll", "fullpath:src/main", "under:Repos ending:swift",
                   "ending:pdf;doc;docx;txt;md;rtf;pages;xls;xlsx;csv;ppt;pptx;key;numbers"]
    for sort in [SortKey.name, SortKey.modified] {
        for query in queries {
            var samples: [Double] = []
            var total = 0
            for _ in 0..<20 {
                let result = engine.search(QueryOptions(query: query, limit: 100, sort: sort,
                                                        ascending: sort == .name), in: store)
                samples.append(result.tookMS)
                total = result.total
            }
            samples.sort()
            let p50 = samples[samples.count / 2], p95 = samples[Int(Double(samples.count) * 0.95) - 1]
            print("query\t\(sort.rawValue)\t\(query.isEmpty ? "<empty>" : query)\t\(total)\tp50 \(String(format: "%.2f", p50)) ms\tp95 \(String(format: "%.2f", p95)) ms")
        }
    }
}

/// `quoll-selftest --equiv <root>`: the new engine must return exactly the entries
/// the 1.0 `Matcher` (kept as a reference oracle) accepts, for a fixed query set.
func runEquivalence(_ arguments: [String]) -> Int32 {
    guard let i = arguments.firstIndex(of: "--equiv"), i + 1 < arguments.count else { return 2 }
    let root = Scanner.standardize(arguments[i + 1])
    let data = (NSTemporaryDirectory() as NSString).appendingPathComponent("quoll-equiv-\(getpid())")
    defer { try? FileManager.default.removeItem(atPath: data) }
    var settings = Preferences.default()
    settings.dataDirectory = data
    let snapshot = (data as NSString).appendingPathComponent("index-equiv")
    let store = IndexStore()
    do {
        _ = try IndexStore.scan(roots: [root], rules: settings.excludeRules, into: snapshot, meta: SnapshotMeta())
        try store.write { try store.adopt(directory: snapshot) }
    } catch {
        print("scan failed: \(error)")
        return 1
    }
    let engine = QueryEngine()
    let everything = engine.search(QueryOptions(query: "", limit: 0, sort: .path), in: store).results
    print("entries\t\(everything.count)")
    let queries = ["kanelbulle", "*.md", "ending:md", "report draft", "readme", "path:src", "kind:folder",
                   "bytes:>1mb", "changed:2025", "starts:test", "ends:.json", "exact:package.json", "word:test",
                   "pattern:^v[0-9]", "!ending:md kind:file", "under:docs", "parent:src", "level:>8", "blank:",
                   "chars:>40", "\"read me\"", "a|b ending:png", "matchcase:README", "fullpath:src/main",
                   "made:<2024", "?.txt", "*test*.swift", "ending:swift|ending:md under:Sources",
                   "ending:png;jpg;jpeg;gif;heic;webp", "kind:file ending:zip;tar;gz;7z;dmg"]
    var mismatches = 0
    for query in queries {
        let fresh = Set(engine.search(QueryOptions(query: query, limit: 0), in: store).results.map(\.path))
        let matcher = Matcher(query: SearchParser.parse(query))
        let oracle = Set(everything.filter { matcher.matches($0) }.map(\.path))
        let ok = fresh == oracle
        if !ok { mismatches += 1 }
        print("\(ok ? "ok  " : "DIFF")\t\(query)\t\(fresh.count)\t\(oracle.count)")
        if !ok {
            for path in fresh.subtracting(oracle).prefix(3) { print("      only new:    \(path)") }
            for path in oracle.subtracting(fresh).prefix(3) { print("      only oracle: \(path)") }
        }
    }
    return mismatches == 0 ? 0 : 1
}

/// `quoll-selftest --m4 [count]`: durable change tracking against real FSEvents.
/// Quit, change the tree, start again: within 5 s the catalog must equal a fresh
/// scan, without a full rescan. Then the same for live changes.
func runDurability(_ arguments: [String]) -> Int32 {
    let fm = FileManager.default
    let n = arguments.firstIndex(of: "--m4").flatMap { i in i + 1 < arguments.count ? Int(arguments[i + 1]) : nil } ?? 10_000
    // Short base path: Unix socket paths are limited to 104 bytes.
    let base = (NSHomeDirectory() as NSString).appendingPathComponent(".qm4-\(getpid())")
    let root = base + "/root", data = base + "/data"
    defer { try? fm.removeItem(atPath: base) }
    var failed = 0
    func check(_ ok: Bool, _ name: String) { print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { failed += 1 } }
    func touch(_ path: String) { fm.createFile(atPath: path, contents: Data("x".utf8)) }

    do {
        for d in 0..<50 { try fm.createDirectory(atPath: "\(root)/d\(d)/sub", withIntermediateDirectories: true) }
        for i in 0..<(n / 5) { touch("\(root)/d\(i % 50)/seed\(i).txt") }
        try fm.createDirectory(atPath: "\(root)/Mover/inner/deep", withIntermediateDirectories: true)
        for i in 0..<200 { touch("\(root)/Mover/inner/deep/m\(i).txt") }
        try fm.createDirectory(atPath: "\(root)/CaseDir", withIntermediateDirectories: true)
        touch("\(root)/CaseDir/c.txt")
        try fm.createDirectory(atPath: "\(root)/Doomed/a/b", withIntermediateDirectories: true)
        for i in 0..<300 { touch("\(root)/Doomed/a/b/x\(i).txt") }
    } catch {
        print("fixture failed: \(error)")
        return 1
    }

    var settings = Preferences.default()
    settings.roots = [root]
    settings.dataDirectory = data
    settings.controlPath = data + "/q.sock"

    func freshPaths(_ scanRoot: String? = nil) -> Set<String> {
        let snapshot = base + "/fresh-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: snapshot) }
        let target = Scanner.canonical(scanRoot ?? root)
        guard (try? IndexStore.scan(roots: [target], rules: settings.excludeRules, into: snapshot, meta: SnapshotMeta())) != nil
        else { return [] }
        let store = IndexStore()
        try? store.write { try store.adopt(directory: snapshot) }
        return store.read { Set((0..<store.count).filter { !store.isDead($0) }.map { store.path($0) }) }
    }
    func noDuplicates(_ service: QuollService) -> Bool {
        let store = service.store
        return store.read { store.liveFiles + store.liveFolders == Set((0..<store.count).filter { !store.isDead($0) }.map { store.path($0) }).count }
    }
    func runShell(_ script: String) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", script]
        try? shell.run()
        shell.waitUntilExit()
    }
    func livePaths(_ service: QuollService) -> Set<String> {
        let store = service.store
        return store.read { Set((0..<store.count).filter { !store.isDead($0) }.map { store.path($0) }) }
    }
    func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if condition() { return Date().timeIntervalSince(start) }
            usleep(50_000)
        }
        return nil
    }

    // 1. First start: full scan, then quit (writes the snapshot + event id).
    let first = QuollService(settings: settings)
    do { try first.start() } catch { print("start failed: \(error)"); return 1 }
    first.drain()
    check(first.fullScans == 1, "first start scans once")
    check(livePaths(first) == freshPaths(), "initial catalog equals a fresh scan")
    first.stop()

    // 2. Changes while Quoll is not running.
    for i in 0..<n { touch("\(root)/d\(i % 50)/new\(i).txt") }
    for i in stride(from: 0, to: n / 5, by: 2) { try? fm.removeItem(atPath: "\(root)/d\(i % 50)/seed\(i).txt") }
    for i in stride(from: 1, to: n / 5, by: 10) {
        try? fm.moveItem(atPath: "\(root)/d\(i % 50)/seed\(i).txt", toPath: "\(root)/d\((i + 7) % 50)/sub/moved\(i).txt")
    }
    try? fm.moveItem(atPath: "\(root)/Mover/inner", toPath: "\(root)/d3/sub/inner-renamed")
    try? fm.moveItem(atPath: "\(root)/CaseDir", toPath: "\(root)/casedir")
    try? fm.removeItem(atPath: "\(root)/Doomed")
    let expected = freshPaths()

    // 3. Second start: load snapshot, replay FSEvents history.
    let started = Date()
    let second = QuollService(settings: settings)
    do { try second.start() } catch { print("restart failed: \(error)"); return 1 }
    let caughtUp = waitUntil(10) { second.replayDone && { second.drain(); return livePaths(second) == expected }() }
    let elapsed = Date().timeIntervalSince(started)
    check(second.fullScans == 0, "restart did not rescan")
    check(caughtUp != nil, "replay converged to a fresh scan (\(String(format: "%.2f", elapsed)) s, \(expected.count) entries)")
    check(caughtUp.map { $0 < 5 } ?? false, "replay within 5 s")
    if caughtUp == nil {
        let live = livePaths(second)
        for p in expected.subtracting(live).sorted().prefix(5) { print("      missing: \(p)") }
        for p in live.subtracting(expected).sorted().prefix(5) { print("      extra:   \(p)") }
    }
    let movedFolder = second.store.read { second.store.resolve(root + "/d3/sub/inner-renamed/deep/m7.txt") }
    check(movedFolder != nil, "moved folder found at its new path")

    // 4. Live changes while running, from another process: the stream ignores
    //    Quoll's own writes (kFSEventStreamCreateFlagIgnoreSelf).
    let script = """
    cd '\(root)'
    for i in $(seq 0 499); do : > d$((i % 50))/live$i.txt; done
    mv d3/sub/inner-renamed d4/back
    for i in $(seq 0 99); do rm -f d$((i % 50))/new$i.txt; done
    mkdir -p fresh/one/two && : > fresh/one/two/f.txt
    """
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-c", script]
    try? shell.run()
    shell.waitUntilExit()
    let liveExpected = freshPaths()
    let liveTime = waitUntil(10) { second.drain(); return livePaths(second) == liveExpected }
    check(liveTime != nil, "live changes converge (\(liveTime.map { String(format: "%.2f", $0) } ?? "timeout") s)")
    if liveTime == nil {
        let live = livePaths(second)
        for p in liveExpected.subtracting(live).sorted().prefix(5) { print("      missing: \(p)") }
        for p in live.subtracting(liveExpected).sorted().prefix(5) { print("      extra:   \(p)") }
        print("      counts: live \(live.count) expected \(liveExpected.count)")
    }
    check(second.fullScans == 0, "live changes did not rescan")
    check(noDuplicates(second), "no entry indexed twice")

    // 4b. Names that fold alike are different files (résumé vs resume).
    runShell("cd '\(root)' && : > d1/résumé.txt && sleep 1.5 && : > d1/resume.txt")
    let foldExpected = freshPaths()
    let foldTime = waitUntil(10) { second.drain(); return livePaths(second) == foldExpected }
    check(foldTime != nil && livePaths(second).contains(root + "/d1/résumé.txt") && livePaths(second).contains(root + "/d1/resume.txt"),
          "résumé.txt and resume.txt both indexed")
    runShell("rm '\(root)/d1/resume.txt'")
    let afterRemove = freshPaths()
    _ = waitUntil(10) { second.drain(); return livePaths(second) == afterRemove }
    check(livePaths(second).contains(root + "/d1/résumé.txt") && !livePaths(second).contains(root + "/d1/resume.txt"),
          "removing resume.txt keeps résumé.txt")

    // 4c. Root replaced while running: one rescan, catalog matches the new root.
    runShell("cd '\(base)' && mv root root.old && mkdir root && : > root/after-replace.txt && rm -rf root.old")
    let replaced = freshPaths()
    let replaceTime = waitUntil(20) { second.drain(); return livePaths(second) == replaced }
    check(replaceTime != nil, "replaced root converges (\(replaceTime.map { String(format: "%.2f", $0) } ?? "timeout") s)")
    check(second.fullScans == 1, "replaced root costs exactly one rescan (\(second.fullScans))")

    // 5. Compaction keeps the live view; reload equals it.
    let before = livePaths(second)
    second.stop()
    print("compaction\t\(String(format: "%.3f", second.lastCompaction)) s for \(before.count) entries")
    let third = QuollService(settings: settings)
    do { try third.start(performInitialScan: false) } catch { print("third start failed: \(error)"); return 1 }
    _ = waitUntil(5) { third.replayDone }
    third.drain()
    check(livePaths(third) == before, "snapshot after compaction reloads the same tree")
    third.stop()

    // 6. A root inside an excluded area (.cache), given through a symlink.
    let inner = base + "/area/.cache/proj"
    try? fm.createDirectory(atPath: inner + "/src", withIntermediateDirectories: true)
    touch(inner + "/src/a.txt")
    try? fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: inner)
    var other = settings
    other.roots = [base + "/link"]
    other.dataDirectory = base + "/data2"
    other.controlPath = base + "/data2/q.sock"
    let fourth = QuollService(settings: other)
    do { try fourth.start() } catch { print("fourth start failed: \(error)"); return 1 }
    fourth.drain()
    check(livePaths(fourth).contains(Scanner.canonical(inner) + "/src/a.txt"), "symlinked root inside an excluded area is indexed")
    runShell("cd '\(inner)' && : > src/b.txt && mkdir -p new && : > new/c.txt")
    let innerExpected = freshPaths(inner)
    let innerTime = waitUntil(10) { fourth.drain(); return livePaths(fourth) == innerExpected }
    check(innerTime != nil, "live changes under that root are kept (\(innerExpected.count) entries)")
    fourth.stop()

    print(failed == 0 ? "\nm4 checks passed" : "\n\(failed) m4 check(s) failed")
    return failed == 0 ? 0 : 1
}

/// `quoll-selftest --volumes <dmg>`: an external-drive index on a writable disk
/// image: indexed on mount, merged into searches, live changes tracked, stopped
/// before unmount, replayed (not rescanned) after reattach.
func runVolumes(_ arguments: [String]) -> Int32 {
    guard let i = arguments.firstIndex(of: "--volumes"), i + 1 < arguments.count else { return 2 }
    let image = arguments[i + 1]
    let fm = FileManager.default
    var failed = 0
    func check(_ ok: Bool, _ name: String) { print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { failed += 1 } }
    func shell(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        try? p.run()
        p.waitUntilExit()
    }
    func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // NSWorkspace notifications
        }
        return false
    }
    let base = (NSHomeDirectory() as NSString).appendingPathComponent(".qvol-\(getpid())")
    defer { try? fm.removeItem(atPath: base) }
    var settings = Preferences.default()
    settings.dataDirectory = base
    settings.indexExternalVolumes = true

    shell("hdiutil attach '\(image)' -quiet")
    let mount = "/Volumes/QuollTestVol"
    check(fm.fileExists(atPath: mount + "/projects/alpha/volume-marker.txt"), "test volume attached")
    check(VolumeIndexes.eligibleVolumes().map(\.path).contains(mount), "volume is eligible")

    let volumes = VolumeIndexes(settings: settings)
    volumes.start()
    let indexed = wait(30) {
        volumes.indexes.first.map { v in v.store.read { v.store.resolve(mount + "/projects/alpha/volume-marker.txt") != nil } } ?? false
    }
    check(indexed, "volume indexed on mount")
    func find(_ q: String) -> [String] {
        MultiSearch.search(QueryOptions(query: q, limit: 50), in: volumes.indexes, interactive: false).results.map(\.path)
    }
    check(find("volume-marker").contains(mount + "/projects/alpha/volume-marker.txt"), "search finds the file on the volume")

    shell("echo y > '\(mount)/projects/alpha/live-added.txt'")
    check(wait(10) { find("live-added").count == 1 }, "live change on the volume is indexed")

    shell("hdiutil detach '\(mount)' -quiet")
    check(wait(10) { volumes.indexes.isEmpty }, "index stopped when the volume unmounted")
    check(!fm.fileExists(atPath: mount), "volume detached (eject not blocked)")

    shell("hdiutil attach '\(image)' -quiet && echo z > '\(mount)/offline.txt'")
    check(wait(30) { find("offline").count == 1 }, "reattach: change made before attach is found")
    check(volumes.indexes.first?.fullScans == 0, "reattach replayed instead of rescanning (\(volumes.indexes.first?.fullScans ?? -1))")
    volumes.stop()
    shell("hdiutil detach '\(mount)' -quiet")
    print(failed == 0 ? "\nvolume checks passed" : "\n\(failed) volume check(s) failed")
    return failed == 0 ? 0 : 1
}
