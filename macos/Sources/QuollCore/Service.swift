import Foundation
import AppKit
import CoreServices

/// Snapshot generations live in `<data>/index-<n>`; `<data>/index` is a symlink to
/// the current one, swapped atomically.
public enum SnapshotLocation {
    public static func current(in data: String) -> String? {
        let link = (data as NSString).appendingPathComponent("index")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        return target.hasPrefix("/") ? target : (data as NSString).appendingPathComponent(target)
    }

    public static func fresh(in data: String) -> String {
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return (data as NSString).appendingPathComponent("index-\(stamp)-\(getpid())")
    }

    /// Points `index` at `directory`, then deletes every other generation. Deleting
    /// a mapped generation is safe: its pages stay valid until unmapped.
    public static func publish(_ directory: String, in data: String) throws {
        let fm = FileManager.default
        let link = (data as NSString).appendingPathComponent("index")
        let temp = link + ".tmp-\(getpid())"
        try? fm.removeItem(atPath: temp)
        try fm.createSymbolicLink(atPath: temp, withDestinationPath: (directory as NSString).lastPathComponent)
        guard rename(temp, link) == 0 else { throw StoreError.io("publish snapshot: \(String(cString: strerror(errno)))") }
        let keep = (directory as NSString).lastPathComponent
        for name in (try? fm.contentsOfDirectory(atPath: data)) ?? [] where name.hasPrefix("index-") && name != keep {
            try? fm.removeItem(atPath: (data as NSString).appendingPathComponent(name))
        }
    }

    public static func bytes(of directory: String?) -> Int64 {
        guard let directory else { return 0 }
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).reduce(Int64(0)) { total, name in
            let attributes = try? fm.attributesOfItem(atPath: (directory as NSString).appendingPathComponent(name))
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}

public final class QuollService {
    public var settings: Preferences
    public let store = IndexStore()
    public let engine = QueryEngine()

    private let startedAt = Date()
    private let stateQueue = DispatchQueue(label: "quoll.service.state", qos: .utility)
    private let lock = NSLock()
    private var control: ControlServer?
    private var monitor: ChangeWatcher?
    private var http: WebServer?
    private var compactWorkItem: DispatchWorkItem?
    private var running = false
    private var lastSnapshotAt = Date()
    /// Highest FSEvents id applied to the store.
    private var appliedEventId: UInt64 = 0
    public private(set) var lastScan: Date?
    public private(set) var replayDone = false
    /// Full scans since start (tests: replay must not need one).
    public private(set) var fullScans = 0
    /// Seconds the last compaction took.
    public private(set) var lastCompaction: TimeInterval = 0

    /// D6 in docs/DECISIONS.md: compact when the overlay holds this many changes, or
    /// after `compactIdle` seconds without events once the snapshot is `compactAge` old.
    public var compactThreshold = 20_000
    public var compactIdle: TimeInterval = 300
    public var compactAge: TimeInterval = 6 * 3600

    public init(settings: Preferences) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    public func start(performInitialScan: Bool = true) throws {
        guard !running else { return }
        try settings.ensureDirectories()
        // The 1.0 JSON catalog is a disposable cache of a format no longer read.
        try? FileManager.default.removeItem(at: settings.catalogURL)

        let loaded = loadSnapshot()

        let server = ControlServer(controlPath: settings.controlPath) { [weak self] request in
            guard let self else {
                return ControlReply.failure("unavailable", "service is not running", id: request.id)
            }
            return self.handle(request)
        }
        try server.start()
        control = server

        let since: UInt64
        if loaded {
            since = store.meta.eventId
            log("loaded snapshot: \(store.meta.count) entries, replaying events since \(since)")
        } else {
            since = ChangeWatcher.currentEventId
            if performInitialScan {
                // Events from now on queue behind the scan on stateQueue.
                stateQueue.async { [weak self] in
                    guard let self else { return }
                    let stats = self.rebuildLocked(eventId: since)
                    self.log("initial scan: \(stats.entries) entries in \(String(format: "%.1f", stats.duration))s")
                }
            }
        }
        appliedEventId = since
        startWatcher(since: since)

        if settings.http.enabled {
            startHTTP()
        }

        lock.lock()
        running = true
        lock.unlock()
        log("listening on \(settings.controlPath)")
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        monitor?.stop()
        monitor = nil
        http?.stop()
        http = nil
        control?.stop()
        control = nil
        stateQueue.sync {
            if store.pendingChanges > 0 { compactLocked(reason: "shutdown") }
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func startWatcher(since: UInt64) {
        monitor?.stop()
        let watcher = ChangeWatcher(paths: settings.roots, sinceWhen: since) { [weak self] events in
            self?.stateQueue.async { self?.apply(events) }
        }
        do {
            try watcher.start()
            monitor = watcher
        } catch {
            log("unable to start FSEvents monitor: \(error.localizedDescription)")
        }
    }

    // MARK: - Snapshot

    private var fingerprint: String {
        (settings.roots + [settings.excludeRules.fingerprint]).joined(separator: "\u{1d}")
    }

    /// Adopts the current snapshot when it matches the roots, rules and volumes.
    private func loadSnapshot() -> Bool {
        guard let directory = SnapshotLocation.current(in: settings.dataDirectory) else { return false }
        do {
            try store.write { try store.adopt(directory: directory) }
        } catch {
            log("snapshot unusable (\(error)); rescanning")
            return false
        }
        let meta = store.meta
        guard meta.rulesFingerprint == fingerprint, meta.roots == settings.roots.filter({ isDirectory($0) }),
              meta.devices == meta.roots.map(ChangeWatcher.volumeUUID(for:)), meta.eventId > 0 else {
            log("roots, rules or volumes changed since the snapshot; rescanning")
            return false
        }
        lastScan = meta.written
        lastSnapshotAt = meta.written
        return true
    }

    private func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// Full scan into a new generation, then swap it in. Runs on stateQueue.
    @discardableResult
    private func rebuildLocked(eventId: UInt64) -> BulkScanner.Stats {
        fullScans += 1
        let directory = SnapshotLocation.fresh(in: settings.dataDirectory)
        var meta = SnapshotMeta()
        meta.eventId = eventId
        meta.rulesFingerprint = fingerprint
        do {
            let roots = settings.roots.filter { isDirectory($0) }
            meta.devices = roots.map(ChangeWatcher.volumeUUID(for:))
            let stats = try ScanHelper.scan(roots: roots, settings: settings, into: directory, meta: meta)
            try store.write { try store.adopt(directory: directory) }
            try SnapshotLocation.publish(directory, in: settings.dataDirectory)
            appliedEventId = max(appliedEventId, eventId)
            lastScan = Date()
            lastSnapshotAt = Date()
            Self.returnFreedMemory()
            return stats
        } catch {
            log("scan failed: \(error)")
            try? FileManager.default.removeItem(atPath: directory)
            return BulkScanner.Stats()
        }
    }

    /// Writes the live tree as a new snapshot and drops the overlay. Runs on stateQueue.
    private func compactLocked(reason: String) {
        let directory = SnapshotLocation.fresh(in: settings.dataDirectory)
        var meta = store.meta
        meta.eventId = appliedEventId
        let started = Date()
        do {
            try store.read { try store.writeSnapshot(to: directory, meta: meta) }
            try store.write { try store.adopt(directory: directory) }
            try SnapshotLocation.publish(directory, in: settings.dataDirectory)
            lastSnapshotAt = Date()
            lastCompaction = Date().timeIntervalSince(started)
            Self.returnFreedMemory()
            log("compacted (\(reason)): \(store.meta.count) entries in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        } catch {
            log("compaction failed: \(error)")
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// Scans and compactions free their buffers, but malloc keeps the pages; hand
    /// them back so the footprint drops to the steady state (D11).
    static func returnFreedMemory() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    private func scheduleCompaction() {
        compactWorkItem?.cancel()
        if store.pendingChanges >= compactThreshold {
            compactLocked(reason: "\(store.pendingChanges) changes")
            return
        }
        guard store.pendingChanges > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.store.pendingChanges > 0,
                  Date().timeIntervalSince(self.lastSnapshotAt) >= self.compactAge else { return }
            self.compactLocked(reason: "idle")
        }
        compactWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + compactIdle, execute: item)
    }

    // MARK: - Indexing (public API)

    @discardableResult
    public func rebuild() -> BulkScanner.Stats {
        stateQueue.sync {
            let id = ChangeWatcher.currentEventId
            return rebuildLocked(eventId: id)
        }
    }

    /// Scans `paths` as the new roots (or rescans the current roots when empty).
    @discardableResult
    public func scan(paths: [String], replaceRoots: Bool = true) -> BulkScanner.Stats {
        let normalized = paths.map(Scanner.standardize)
        if replaceRoots, !normalized.isEmpty, normalized != settings.roots {
            settings.roots = normalized
            try? settings.save()
            let stats = rebuild()
            startWatcher(since: store.meta.eventId)
            return stats
        }
        return rebuild()
    }

    /// Blocks until all queued change batches have been applied (tests, CLI).
    public func drain() {
        stateQueue.sync {}
    }

    // MARK: - Change reconciliation

    private static let debug = ProcessInfo.processInfo.environment["QUOLL_DEBUG"] != nil

    private func apply(_ events: [ChangeEvent]) {
        guard !events.isEmpty else { return }
        if Self.debug {
            log("batch: \(events.count) events, first \(events[0].path) flags \(String(events[0].flags, radix: 16)) history-done \(events.contains(where: \.isHistoryDone))")
        }
        let lastId = events.map(\.id).max() ?? 0
        if events.contains(where: \.isHistoryDone) { replayDone = true }
        if let event = events.first(where: \.requiresFullRescan) {
            log("FSEvents asked for a rescan (flags \(String(event.flags, radix: 16)))")
            rebuildLocked(eventId: ChangeWatcher.currentEventId)
            return
        }
        let rules = settings.excludeRules
        var mustScan = Set<String>()
        var unique = Set<String>()
        for event in events where !event.isHistoryDone {
            let path = normalize(event.path)
            unique.insert(path)
            if event.mustScanSubdirectories { mustScan.insert(path) }
        }
        // Parents before children, so a new folder exists before its contents.
        let ordered = unique.sorted { a, b in
            let ca = a.utf8.reduce(0) { $0 + ($1 == 47 ? 1 : 0) }, cb = b.utf8.reduce(0) { $0 + ($1 == 47 ? 1 : 0) }
            return ca != cb ? ca < cb : a < b
        }
        store.write {
            var missing: [String] = []
            for path in ordered {
                guard isUnderRoot(path) else { continue }
                if rules.excludesAnyComponent(of: path) {
                    if let id = store.resolve(path), id >= store.rootCount { store.removeSubtree(id) }
                    continue
                }
                var st = stat()
                if lstat(path, &st) != 0 {
                    missing.append(path)
                    continue
                }
                upsert(path, st, rules: rules, rescan: mustScan.contains(path))
            }
            // Removals last: a folder that moved was re-parented above, by inode.
            for path in missing {
                var st = stat()
                guard lstat(path, &st) != 0, let id = store.resolve(path), id >= store.rootCount else { continue }
                store.removeSubtree(id)
            }
        }
        appliedEventId = max(appliedEventId, lastId)
        if store.pendingChanges > 0 { lastScan = Date() }
        scheduleCompaction()
    }

    /// FSEvents may report firmlinked paths (`/System/Volumes/Data/Users/...`).
    private func normalize(_ path: String) -> String {
        var p = path
        let data = "/System/Volumes/Data"
        if p.hasPrefix(data + "/") && !settings.roots.contains(where: { $0.hasPrefix(data) }) {
            p = String(p.dropFirst(data.count))
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func isUnderRoot(_ path: String) -> Bool {
        store.meta.roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    private static func entryMeta(_ st: stat) -> EntryMeta {
        EntryMeta(mtime: UInt32(clamping: max(0, st.st_mtimespec.tv_sec)),
                  ctime: UInt32(clamping: max(0, st.st_birthtimespec.tv_sec)),
                  size: st.st_mode & S_IFMT == S_IFDIR ? 0 : UInt64(max(0, st.st_size)))
    }

    /// The on-disk spelling of the last component (case-insensitive volumes accept
    /// any case in lookups; the catalog must store the real one).
    private static func trueName(of path: String) -> String? {
        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = 0x0000_0001 // ATTR_CMN_NAME
        var buffer = [UInt8](repeating: 0, count: 4 + 8 + 1024)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            getattrlist(path, &list, raw.baseAddress!, raw.count, UInt32(FSOPT_NOFOLLOW)) == 0
        }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw -> String in
            let ref = raw.baseAddress! + 4
            let offset = Int(ref.load(as: Int32.self))
            let length = Int(ref.load(fromByteOffset: 4, as: UInt32.self))
            let start = ref + offset
            return String(decoding: UnsafeRawBufferPointer(start: start, count: max(0, length - 1)), as: UTF8.self)
        }
    }

    /// Brings one existing path into the catalog. Caller holds the write lock.
    private func upsert(_ path: String, _ st: stat, rules: ExcludeRules, rescan: Bool) {
        let isDir = st.st_mode & S_IFMT == S_IFDIR
        let isLink = st.st_mode & S_IFMT == S_IFLNK
        let meta = Self.entryMeta(st)
        let name = Self.trueName(of: path) ?? (path as NSString).lastPathComponent

        if let id = store.resolve(path) {
            let sameKind = store.isDirectory(id) == isDir
            let sameFolder = !isDir || store.inode(ofDirectory: id).map { $0 == 0 || $0 == UInt64(st.st_ino) } ?? true
            if sameKind && sameFolder {
                store.setMeta(id, meta)
                if String(decoding: store.raw(id), as: UTF8.self) != name, id >= store.rootCount {
                    rename(id, to: store.parent(id), name: name)
                }
                if isDir && rescan {
                    for child in store.children(of: id) { store.removeSubtree(child) }
                    store.scanSubtree(id, path: path, rules: rules)
                }
                return
            }
            guard id >= store.rootCount else { return }
            store.removeSubtree(id)
        }

        let parentPath = (path as NSString).deletingLastPathComponent
        guard let parent = ensureFolder(parentPath, rules: rules) else { return }

        if isDir, let moved = store.directory(withInode: UInt64(st.st_ino)), moved >= store.rootCount {
            let oldPath = store.path(moved)
            var old = stat()
            if oldPath != path && (lstat(oldPath, &old) != 0 || old.st_ino != st.st_ino) {
                rename(moved, to: parent, name: name)
                store.setMeta(moved, meta)
                return
            }
        }

        let raw = Array(name.utf8), folded = Fold.fold(name)
        let flags = (isDir ? EntryFlags.directory : 0) | (isLink ? EntryFlags.symlink : 0)
        let id = raw.withUnsafeBufferPointer { r in
            folded.withUnsafeBufferPointer { f in
                store.appendDelta(parent: parent, raw: r, folded: f, flags: flags, meta: meta, inode: UInt64(st.st_ino))
            }
        }
        if isDir && !isLink {
            let inherited = rules.verdict(name: name, path: path, isDirectory: true) == .passThrough
            store.scanSubtree(id, path: path, rules: rules, inherited: inherited)
        }
    }

    private func rename(_ id: Int, to parent: Int, name: String) {
        let raw = Array(name.utf8), folded = Fold.fold(name)
        raw.withUnsafeBufferPointer { r in
            folded.withUnsafeBufferPointer { f in store.move(id, to: parent, raw: r, folded: f) }
        }
    }

    /// Id of the folder at `path`, adding missing ancestors (coalesced events can
    /// report a deep path before its parents).
    private func ensureFolder(_ path: String, rules: ExcludeRules) -> Int? {
        if let id = store.resolve(path) { return store.isDirectory(id) ? id : nil }
        guard isUnderRoot(path), !rules.excludesAnyComponent(of: path) else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        upsert(path, st, rules: rules, rescan: false)
        return store.resolve(path)
    }

    // MARK: - Status

    public func status() -> CatalogStatus {
        let counts = store.read { (store.liveFiles, store.liveFolders, store.snapshotDirectory) }
        return CatalogStatus(
            files: counts.0,
            directories: counts.1,
            roots: settings.roots,
            lastScan: lastScan,
            catalogBytes: SnapshotLocation.bytes(of: counts.2),
            controlPath: settings.controlPath,
            uptime: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: - IPC commands

    public func handle(_ request: ControlRequest) -> ControlReply {
        switch request.command {
        case "ping":
            return ControlReply(id: request.id, message: "pong")

        case "search":
            let options = QueryOptions(
                query: request.query ?? "",
                limit: request.limit ?? settings.defaultLimit,
                offset: request.offset ?? 0,
                sort: request.sort ?? .name,
                ascending: request.ascending ?? true
            )
            let response = engine.search(options, in: store)
            return ControlReply(
                id: request.id,
                count: response.count,
                total: response.total,
                tookMS: response.tookMS,
                results: response.results,
                warnings: response.warnings
            )

        case "status":
            return ControlReply(id: request.id, status: status())

        case "scan", "rebuild":
            // Long scans must not hit the client's socket timeout: run in the
            // background and report through `status`.
            let paths = request.command == "scan" ? (request.paths ?? []) : []
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let stats = self.scan(paths: paths, replaceRoots: !paths.isEmpty)
                self.log("scan: \(stats.entries) entries in \(String(format: "%.1f", stats.duration))s")
            }
            return ControlReply(id: request.id, message: "scan started; see `quoll status`")

        case "forget":
            guard let path = request.path else {
                return .failure("bad_request", "forget requires path", id: request.id)
            }
            let target = Scanner.standardize(path)
            stateQueue.sync {
                store.write {
                    if let id = store.resolve(target), id >= store.rootCount { store.removeSubtree(id) }
                }
                scheduleCompaction()
            }
            return ControlReply(id: request.id, message: "forgotten")

        case "open":
            guard let path = request.path else {
                return .failure("bad_request", "open requires path", id: request.id)
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return ControlReply(id: request.id, message: "opened")

        case "reveal":
            guard let path = request.path else {
                return .failure("bad_request", "reveal requires path", id: request.id)
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return ControlReply(id: request.id, message: "revealed")

        case "export":
            let format = ReportFormat(rawValue: request.format ?? "json") ?? .json
            let options = QueryOptions(
                query: request.query ?? "",
                limit: 0,
                sort: request.sort ?? .path,
                ascending: true
            )
            let response = engine.search(options, in: store)
            let data = ReportWriter.export(response.results, format: format)
            return ControlReply(
                id: request.id,
                count: response.results.count,
                data: String(data: data, encoding: .utf8) ?? ""
            )

        case "stop":
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.stop()
            }
            return ControlReply(id: request.id, message: "shutting down")

        default:
            return .failure("unknown_command", "unknown command '\(request.command)'", id: request.id)
        }
    }

    // MARK: - HTTP

    private func startHTTP() {
        let server = WebServer(
            port: settings.http.port,
            username: settings.http.username,
            password: settings.http.password
        ) { [weak self] request in
            guard let self else {
                return WebReply.text("service stopped", status: 500)
            }
            return self.handleHTTP(request)
        }
        do {
            try server.start()
            http = server
            log("HTTP listening on port \(settings.http.port)")
        } catch {
            log("unable to start HTTP server: \(error.localizedDescription)")
        }
    }

    private func handleHTTP(_ request: WebRequest) -> WebReply {
        switch request.path {
        case "/search":
            let query = (request.query["q"] ?? "").replacingOccurrences(of: "+", with: " ")
            let limit = Int(request.query["limit"] ?? "") ?? settings.defaultLimit
            let sort = SortKey(rawValue: request.query["sort"] ?? "") ?? .name
            let ascending = (request.query["asc"] ?? "1") != "0"
            let options = QueryOptions(
                query: query,
                limit: limit,
                offset: Int(request.query["offset"] ?? "") ?? 0,
                sort: sort,
                ascending: ascending
            )
            let response = engine.search(options, in: store)

            if request.query["json"] == "1" || (request.headers["accept"] ?? "").contains("application/json") {
                return .json(response)
            }
            return .text(Self.html(results: response, query: query), contentType: "text/html; charset=utf-8")

        case "/status":
            return .json(status())

        case "/export":
            let format = ReportFormat(rawValue: request.query["format"] ?? "json") ?? .json
            let options = QueryOptions(
                query: (request.query["q"] ?? "").replacingOccurrences(of: "+", with: " "),
                limit: 0,
                sort: .path,
                ascending: true
            )
            let response = engine.search(options, in: store)
            let data = ReportWriter.export(response.results, format: format)
            let contentType: String
            switch format {
            case .json: contentType = "application/json"
            case .csv: contentType = "text/csv"
            case .tsv: contentType = "text/tab-separated-values"
            }
            return WebReply(
                status: 200,
                headers: ["Content-Type": "\(contentType); charset=utf-8"],
                body: data
            )

        default:
            return serveStatic(request.path)
        }
    }

    private func serveStatic(_ path: String) -> WebReply {
        let root = settings.http.root
            ?? (settings.dataDirectory as NSString).appendingPathComponent("http")
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.contains("..") else {
            return .text("not found", status: 404)
        }
        var file = (root as NSString).appendingPathComponent(decoded)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), isDirectory.boolValue {
            file = (file as NSString).appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            return .text("not found", status: 404)
        }
        let ext = (file as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "html", "htm": contentType = "text/html; charset=utf-8"
        case "css": contentType = "text/css"
        case "js": contentType = "application/javascript"
        case "json": contentType = "application/json"
        case "png": contentType = "image/png"
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "svg": contentType = "image/svg+xml"
        default: contentType = "application/octet-stream"
        }
        return WebReply(headers: ["Content-Type": contentType], body: data)
    }

    private static func html(results: QueryResult, query: String) -> String {
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        let rows = results.results.map { entry in
            "<tr><td><a href=\"file://\(escape(entry.path))\">\(escape(entry.name))</a></td><td class=\"path\">\(escape((entry.path as NSString).deletingLastPathComponent))</td><td class=\"num\">\(entry.isDirectory ? "" : escape(entry.formattedSize))</td></tr>"
        }.joined()

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <title>Quoll</title>
        <style>
        body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;margin:24px;color:#111}
        input[type=search]{width:min(720px,100%);padding:10px 12px;font-size:16px;border:1px solid #ccc;border-radius:8px}
        table{border-collapse:collapse;width:100%;margin-top:16px}
        td,th{text-align:left;padding:6px 8px;border-bottom:1px solid #eee}
        .path{color:#777}.num{text-align:right;white-space:nowrap}
        form{margin-bottom:8px}
        </style></head><body>
        <form action="/search" method="get">
        <input type="search" name="q" value="\(escape(query))" placeholder="Search files..." autofocus>
        </form>
        <div>\(results.total) results in \(String(format: "%.1f", results.tookMS)) ms</div>
        <table><thead><tr><th>Name</th><th>Path</th><th>Size</th></tr></thead><tbody>\(rows)</tbody></table>
        </body></html>
        """
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[quoll] \(message)\n".utf8))
    }
}
