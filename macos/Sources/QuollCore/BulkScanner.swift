import Foundation

/// One folder's children, collected by a scanner worker before it is appended
/// to the sink in one locked step. Buffers are reused per worker.
final class ScanBatch {
    struct Item {
        var rawStart: Int32
        var rawLen: Int32
        var foldStart: Int32
        var foldLen: Int32
        var flags: UInt8
        /// 0 = do not walk, 1 = walk, 2 = walk with inherited exclusion (pass-through).
        var descend: UInt8
        var meta: EntryMeta
        var inode: UInt64
    }

    var raw: [UInt8] = []
    var folded: [UInt8] = []
    var items: [Item] = []
    var order: [Int32] = []

    func reset() {
        raw.removeAll(keepingCapacity: true)
        folded.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    /// Sort by (folded, raw) so the sink can store children in lookup order.
    func sort() {
        order = (0..<Int32(items.count)).map { $0 }
        raw.withUnsafeBufferPointer { r in
            folded.withUnsafeBufferPointer { f in
                let items = self.items
                order.sort { a, b in
                    let x = items[Int(a)], y = items[Int(b)]
                    let c = IndexStore.compare(UnsafeBufferPointer(rebasing: f[Int(x.foldStart)..<Int(x.foldStart + x.foldLen)]),
                                               UnsafeBufferPointer(rebasing: f[Int(y.foldStart)..<Int(y.foldStart + y.foldLen)]))
                    if c != 0 { return c < 0 }
                    return IndexStore.compare(UnsafeBufferPointer(rebasing: r[Int(x.rawStart)..<Int(x.rawStart + x.rawLen)]),
                                              UnsafeBufferPointer(rebasing: r[Int(y.rawStart)..<Int(y.rawStart + y.rawLen)])) < 0
                }
            }
        }
    }

    func forEachSorted(_ body: (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>, Item) -> Void) {
        raw.withUnsafeBufferPointer { r in
            folded.withUnsafeBufferPointer { f in
                for index in order {
                    let item = items[Int(index)]
                    body(UnsafeBufferPointer(rebasing: r[Int(item.rawStart)..<Int(item.rawStart + item.rawLen)]),
                         UnsafeBufferPointer(rebasing: f[Int(item.foldStart)..<Int(item.foldStart + item.foldLen)]),
                         item)
                }
            }
        }
    }

    func name(of index: Int32) -> String {
        let item = items[Int(index)]
        return String(decoding: raw[Int(item.rawStart)..<Int(item.rawStart + item.rawLen)], as: UTF8.self)
    }
}

/// Appends scanned children to the store's delta (subtree scans after a change).
final class DeltaSink: ScanSink {
    let store: IndexStore
    init(store: IndexStore) { self.store = store }

    func appendChildren(of parent: UInt32, inode: UInt64, batch: ScanBatch) -> UInt32 {
        let first = UInt32(store.count)
        batch.forEachSorted { r, f, item in
            store.appendDelta(parent: Int(parent), raw: r, folded: f, flags: item.flags, meta: item.meta, inode: item.inode)
        }
        return first
    }
}

/// Parallel directory walker built on `getattrlistbulk`: one syscall returns a
/// whole buffer of entries with name, type, times, flags, inode and size.
public final class BulkScanner {
    /// D4 in docs/DECISIONS.md: more than 4 workers made the walk slower on the Air.
    public static var defaultThreads: Int { min(4, ProcessInfo.processInfo.activeProcessorCount) }

    struct Job {
        var path: String
        var id: UInt32
        var inode: UInt64
        var inherited: Bool
        var device: Int32
    }

    public struct Stats {
        public var entries = 0
        public var folders = 0
        public var unreadable = 0
        public var duration: TimeInterval = 0
    }

    private let rules: ExcludeRules
    private let threads: Int
    private let condition = NSCondition()
    private var stack: [Job] = []
    private var busy = 0
    private let sinkLock = NSLock()
    private var stats = Stats()

    public init(rules: ExcludeRules, threads: Int = BulkScanner.defaultThreads) {
        self.rules = rules
        self.threads = max(1, threads)
    }

    /// Never let a walk download iCloud / File Provider content.
    static let materializationOff: Void = {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }()

    func run(_ jobs: [Job], sink: ScanSink) -> Stats {
        _ = Self.materializationOff
        let started = Date()
        stack = jobs
        busy = 0
        stats = Stats()
        DispatchQueue.concurrentPerform(iterations: threads) { _ in worker(sink: sink) }
        stats.duration = Date().timeIntervalSince(started)
        return stats
    }

    private func worker(sink: ScanSink) {
        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        let batch = ScanBatch()
        var children: [Job] = []
        while let job = next() {
            children.removeAll(keepingCapacity: true)
            scan(job, buffer: buffer, capacity: capacity, batch: batch, sink: sink, children: &children)
            finish(pushing: children)
        }
    }

    private func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && busy > 0 { condition.wait() }
        guard let job = stack.popLast() else {
            condition.broadcast()
            return nil
        }
        busy += 1
        return job
    }

    private func finish(pushing jobs: [Job]) {
        condition.lock()
        stack.append(contentsOf: jobs)
        busy -= 1
        condition.broadcast()
        condition.unlock()
    }

    // Attribute bits (sys/attr.h), spelled out because Swift imports them inconsistently.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnCrTime: UInt32 = 0x0000_0200
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnReturned: UInt32 = 0x8000_0000
    private static let fileDataLength: UInt32 = 0x0000_0200
    private static let vDir: UInt32 = 2
    private static let vLink: UInt32 = 5
    private static let sfDataless: UInt32 = 0x4000_0000

    private func scan(_ job: Job, buffer: UnsafeMutableRawPointer, capacity: Int, batch: ScanBatch,
                      sink: ScanSink, children: inout [Job]) {
        batch.reset()
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        var unreadable = fd < 0
        var folder = stat()
        if fd >= 0, fstat(fd, &folder) == 0, folder.st_dev != job.device {
            // A mount point inside the root: stay on the root's volume.
            close(fd)
            batch.reset()
            sinkLock.lock()
            _ = sink.appendChildren(of: job.id, inode: job.inode, batch: batch)
            stats.folders += 1
            sinkLock.unlock()
            return
        }
        if fd >= 0 {
            defer { close(fd) }
            var list = attrlist()
            list.bitmapcount = 5
            list.commonattr = Self.cmnReturned | Self.cmnName | Self.cmnDevID | Self.cmnObjType
                | Self.cmnCrTime | Self.cmnModTime | Self.cmnFlags | Self.cmnFileID
            list.fileattr = Self.fileDataLength
            let needPaths = rules.needsPaths(below: job.path)
            let prefix = job.path == "/" ? "/" : job.path + "/"
            while true {
                let n = getattrlistbulk(fd, &list, buffer, capacity, 0)
                if n < 0 { unreadable = batch.items.isEmpty; break }
                if n == 0 { break }
                var p = UnsafeRawPointer(buffer)
                for _ in 0..<n {
                    let length = Int(p.load(as: UInt32.self))
                    parse(p, job: job, prefix: prefix, needPaths: needPaths, batch: batch)
                    p += length
                }
            }
        }
        batch.sort()

        sinkLock.lock()
        let first = sink.appendChildren(of: job.id, inode: job.inode, batch: batch)
        stats.entries += batch.items.count
        stats.folders += 1
        if unreadable { stats.unreadable += 1 }
        sinkLock.unlock()

        for (position, index) in batch.order.enumerated() {
            let item = batch.items[Int(index)]
            guard item.descend > 0 else { continue }
            children.append(Job(path: prefix(of: job) + batch.name(of: index), id: first + UInt32(position),
                                inode: item.inode, inherited: item.descend == 2, device: job.device))
        }
    }

    @inline(__always) private func prefix(of job: Job) -> String {
        job.path == "/" ? "/" : job.path + "/"
    }

    @inline(__always)
    private func parse(_ entry: UnsafeRawPointer, job: Job, prefix: String, needPaths: Bool, batch: ScanBatch) {
        var q = entry + 4
        let common = q.load(as: UInt32.self)
        let file = (q + 12).load(as: UInt32.self)
        q += 20
        guard common & Self.cmnName != 0 else { return }
        let nameRef = q
        let namePointer = (nameRef + Int(nameRef.load(as: Int32.self))).assumingMemoryBound(to: UInt8.self)
        q += 8
        var device = job.device
        if common & Self.cmnDevID != 0 { device = q.load(as: Int32.self); q += 4 }
        var type: UInt32 = 0
        if common & Self.cmnObjType != 0 { type = q.load(as: UInt32.self); q += 4 }
        var ctime: UInt32 = 0
        if common & Self.cmnCrTime != 0 { ctime = Self.seconds(q.loadUnaligned(as: Int64.self)); q += 16 }
        var mtime: UInt32 = 0
        if common & Self.cmnModTime != 0 { mtime = Self.seconds(q.loadUnaligned(as: Int64.self)); q += 16 }
        var bsdFlags: UInt32 = 0
        if common & Self.cmnFlags != 0 { bsdFlags = q.load(as: UInt32.self); q += 4 }
        var inode: UInt64 = 0
        if common & Self.cmnFileID != 0 { inode = q.loadUnaligned(as: UInt64.self); q += 8 }
        var size: UInt64 = 0
        if file & Self.fileDataLength != 0 { size = UInt64(max(0, q.loadUnaligned(as: Int64.self))) }

        let nameLength = strlen(UnsafeRawPointer(namePointer).assumingMemoryBound(to: CChar.self))
        let nameBytes = UnsafeBufferPointer(start: namePointer, count: nameLength)
        let name = String(decoding: nameBytes, as: UTF8.self)
        let isDirectory = type == Self.vDir
        let isLink = type == Self.vLink
        let verdict = rules.verdict(name: name, path: needPaths ? prefix + name : "", isDirectory: isDirectory,
                                    inheritedExclusion: job.inherited, checkPaths: needPaths)
        if verdict == .skip { return }

        let rawStart = Int32(batch.raw.count)
        batch.raw.append(contentsOf: nameBytes)
        let foldStart = Int32(batch.folded.count)
        Fold.append(nameBytes, to: &batch.folded)
        var walk: UInt8 = 0
        if isDirectory && !isLink && device == job.device && bsdFlags & Self.sfDataless == 0 {
            walk = verdict == .passThrough ? 2 : 1
        }
        batch.items.append(ScanBatch.Item(
            rawStart: rawStart, rawLen: Int32(nameLength),
            foldStart: foldStart, foldLen: Int32(batch.folded.count) - foldStart,
            flags: (isDirectory ? EntryFlags.directory : 0) | (isLink ? EntryFlags.symlink : 0),
            descend: walk,
            meta: EntryMeta(mtime: mtime, ctime: ctime, size: isDirectory ? 0 : size),
            inode: inode))
    }

    @inline(__always) static func seconds(_ value: Int64) -> UInt32 {
        UInt32(clamping: max(0, value))
    }
}

// MARK: - Full scans and subtree scans

extension IndexStore {
    /// Scans `roots` into a new snapshot directory (streamed, nothing held in memory).
    public static func scan(roots: [String], rules: ExcludeRules, into directory: String,
                            meta: SnapshotMeta, threads: Int = BulkScanner.defaultThreads) throws -> BulkScanner.Stats {
        let writer = try SnapshotWriter(directory: directory)
        var jobs: [BulkScanner.Job] = []
        var meta = meta
        meta.roots = []
        for root in roots {
            var st = stat()
            guard lstat(root, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            let rawName = Array(root.utf8)
            let foldedName = Fold.fold((root as NSString).lastPathComponent)
            let id = rawName.withUnsafeBufferPointer { r in
                foldedName.withUnsafeBufferPointer { f in
                    writer.appendEntry(parent: UInt32.max, raw: r, folded: f, flags: EntryFlags.directory,
                                       meta: EntryMeta(mtime: UInt32(clamping: max(0, st.st_mtimespec.tv_sec)),
                                                       ctime: UInt32(clamping: max(0, st.st_birthtimespec.tv_sec)),
                                                       size: 0))
                }
            }
            meta.roots.append(root)
            jobs.append(BulkScanner.Job(path: root, id: id, inode: UInt64(st.st_ino), inherited: false, device: st.st_dev))
        }
        // One walk per root, each with rules relative to that root (D13).
        var stats = BulkScanner.Stats()
        for job in jobs {
            let part = BulkScanner(rules: rules.relative(to: job.path), threads: threads).run([job], sink: writer)
            stats.entries += part.entries + 1
            stats.folders += part.folders
            stats.unreadable += part.unreadable
            stats.duration += part.duration
        }
        try writer.finish(meta: meta)
        return stats
    }

    /// Walks the folder `id` (already in the store) at `path` into the delta.
    /// Caller holds the write lock.
    @discardableResult
    public func scanSubtree(_ id: Int, path: String, rules: ExcludeRules, inherited: Bool = false) -> BulkScanner.Stats {
        var st = stat()
        guard lstat(path, &st) == 0 else { return BulkScanner.Stats() }
        let job = BulkScanner.Job(path: path, id: UInt32(id), inode: UInt64(st.st_ino), inherited: inherited,
                                  device: st.st_dev)
        return BulkScanner(rules: rules, threads: BulkScanner.defaultThreads).run([job], sink: DeltaSink(store: self))
    }
}
