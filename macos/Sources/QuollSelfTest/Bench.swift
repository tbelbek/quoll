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
    let queries = ["", "kanelbulle", "*.md", "ending:md", "path:.config json", "report draft", "README"]
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
                   "made:<2024", "?.txt", "*test*.swift", "ending:swift|ending:md under:Sources"]
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
