import AppKit

/// Separate indexes for external drives. Each mounted local, writable, external
/// volume gets its own `QuollService` (snapshot under `<data>/volumes/<uuid>`,
/// FSEvents replay, scans in the helper process); the index is stopped before the
/// volume unmounts so it never blocks an eject. The snapshot stays on the Mac, so
/// reattaching a drive replays its changes instead of rescanning.
public final class VolumeIndexes {
    private var base: Preferences
    private var services: [String: QuollService] = [:]   // mount path → index
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    public var onChange: (() -> Void)?

    public init(settings: Preferences) {
        base = settings
    }

    deinit { stop() }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] note in
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                DispatchQueue.global(qos: .utility).async { self?.attach(url) }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: nil) { [weak self] note in
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { self?.detach(url.path) }
        })
        for url in Self.eligibleVolumes() { attach(url) }
    }

    public func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        lock.lock()
        let all = services
        services = [:]
        lock.unlock()
        all.values.forEach { $0.stop() }
    }

    /// Indexes currently attached (for searching and status).
    public var indexes: [QuollService] {
        lock.lock()
        defer { lock.unlock() }
        return Array(services.values)
    }

    public var mountPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return services.keys.sorted()
    }

    private static let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
                                                 .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeUUIDStringKey]

    /// Local, writable, browsable, non-internal volumes under /Volumes (USB/Thunderbolt
    /// drives, writable disk images). Network shares and read-only images are skipped.
    public static func eligibleVolumes() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter(isEligible)
    }

    static func isEligible(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
        return v.volumeIsLocal == true && v.volumeIsInternal != true && v.volumeIsReadOnly != true
            && v.volumeIsRootFileSystem != true && v.volumeIsBrowsable != false && v.volumeUUIDString != nil
    }

    private func attach(_ url: URL) {
        guard Self.isEligible(url), let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return }
        let path = Scanner.canonical(url.path)
        lock.lock()
        let known = services[path] != nil
        lock.unlock()
        guard !known else { return }
        // Right after a mount the volume's FSEvents id is not available yet; the
        // snapshot check needs it, or every reattach would rescan.
        for _ in 0..<50 where ChangeWatcher.volumeUUID(for: path).isEmpty { usleep(100_000) }
        var settings = base
        settings.roots = [path]
        settings.dataDirectory = (base.dataDirectory as NSString).appendingPathComponent("volumes/\(uuid)")
        settings.controlPath = (settings.dataDirectory as NSString).appendingPathComponent("unused.sock")
        settings.http.enabled = false
        let service = QuollService(settings: settings, controlServer: false)
        do {
            try service.start()
        } catch {
            return
        }
        lock.lock()
        services[path] = service
        lock.unlock()
        onChange?()
    }

    private func detach(_ path: String) {
        let key = Scanner.canonical(path)
        lock.lock()
        let service = services.removeValue(forKey: key) ?? services.removeValue(forKey: path)
        lock.unlock()
        service?.stop()
        if service != nil { onChange?() }
    }
}

/// Searches several indexes and merges the pages (each index returns its own top
/// `offset + limit`; the merge keeps the same order the engine uses).
public enum MultiSearch {
    public static func search(_ options: QueryOptions, in services: [QuollService], interactive: Bool) -> QueryResult {
        guard services.count > 1 else {
            return services.first.map { $0.engine.search(options, in: $0.store, cancellable: interactive) }
                ?? QueryResult(query: options.query, count: 0, total: 0, tookMS: 0, truncated: false, results: [])
        }
        var wide = options
        wide.offset = 0
        wide.limit = options.limit <= 0 ? 0 : options.offset + options.limit
        let parts = services.enumerated().map { index, service in
            // Only the main index takes part in interactive cancellation.
            service.engine.search(wide, in: service.store, cancellable: interactive && index == 0)
        }
        if parts.contains(where: { $0.warnings.contains("cancelled") }) {
            var cancelled = parts[0]
            cancelled.warnings = ["cancelled"]
            return cancelled
        }
        let merged = parts.flatMap(\.results).sorted { before($0, $1, options) }
        let start = min(options.offset, merged.count)
        let end = options.limit <= 0 ? merged.count : min(merged.count, start + options.limit)
        let total = parts.reduce(0) { $0 + $1.total }
        var result = QueryResult(query: options.query, count: end - start, total: total,
                                 tookMS: parts.map(\.tookMS).max() ?? 0, truncated: end < total,
                                 results: Array(merged[start..<end]))
        result.warnings = Array(Set(parts.flatMap(\.warnings)))
        return result
    }

    static func before(_ a: FileEntry, _ b: FileEntry, _ options: QueryOptions) -> Bool {
        let asc = options.ascending
        func ordered<T: Comparable>(_ x: T, _ y: T) -> Bool? { x == y ? nil : (asc ? x < y : x > y) }
        let decided: Bool?
        switch options.sort {
        case .size: decided = ordered(a.size, b.size)
        case .modified: decided = ordered(a.modified, b.modified)
        case .created: decided = ordered(a.created, b.created)
        case .accessed: decided = ordered(a.accessed, b.accessed)
        case .level: decided = ordered(a.level, b.level)
        case .fileExtension: decided = ordered(a.fileExtension, b.fileExtension)
        case .path:
            // Same key as the engine: folded path bytes.
            let pa = Fold.fold(a.path), pb = Fold.fold(b.path)
            decided = pa == pb ? nil : (asc ? pa.lexicographicallyPrecedes(pb) : pb.lexicographicallyPrecedes(pa))
        case .name: decided = nil
        }
        if let decided { return decided }
        let fa = Fold.fold(a.name), fb = Fold.fold(b.name)
        if fa != fb { return asc || options.sort != .name ? fa.lexicographicallyPrecedes(fb) : fb.lexicographicallyPrecedes(fa) }
        return a.path < b.path
    }
}
