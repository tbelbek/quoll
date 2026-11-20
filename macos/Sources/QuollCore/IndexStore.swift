import Foundation
import CoreServices

/// Snapshot layout (one directory per generation, `index` symlink points at the
/// current one). All per-entry columns are indexed by entry id:
///
///   folded.bin / folded.off   folded names, NUL-terminated; u32 start offsets (+ sentinel)
///   raw.bin    / raw.off      display names, same layout
///   parent.u32                parent id, UInt32.max for roots
///   mtime.u32, ctime.u32      seconds since 1970 (modification, creation)
///   size.u64                  logical size in bytes (0 for folders)
///   flags.u8                  EntryFlags
///   dirs.bin                  DirRecord per folder, sorted by entry id
///   dirs.inode                u32 indices into dirs.bin, sorted by inode
///   meta.json                 SnapshotMeta
///
/// Invariants of a snapshot (scan or compaction output): roots are ids
/// 0..<roots.count; the children of a folder are one contiguous id range sorted
/// by (folded, raw) name; a folder's id is smaller than its children's ids.
public struct DirRecord {
    public var entry: UInt32
    public var childStart: UInt32
    public var childCount: UInt32
    public var reserved: UInt32 = 0
    public var inode: UInt64
}

public enum EntryFlags {
    public static let directory: UInt8 = 1
    public static let symlink: UInt8 = 2
}

public struct EntryMeta: Equatable {
    public var mtime: UInt32
    public var ctime: UInt32
    public var size: UInt64

    public init(mtime: UInt32, ctime: UInt32, size: UInt64) {
        self.mtime = mtime
        self.ctime = ctime
        self.size = size
    }
}

public struct SnapshotMeta: Codable, Equatable {
    public static let formatVersion = 2
    public var version: Int = SnapshotMeta.formatVersion
    public var count: Int = 0
    public var roots: [String] = []
    /// FSEvents id taken before the scan began; replay starts here.
    public var eventId: UInt64 = 0
    /// FSEvents volume UUID per root (same order as `roots`).
    public var devices: [String] = []
    /// Roots + effective rules; a mismatch on start means a rescan.
    public var rulesFingerprint: String = ""
    public var written: Date = Date()

    public init() {}
}

/// Receives a scanned folder's children in sorted order. Called with the
/// scanner's lock held, so implementations need no locking of their own.
protocol ScanSink: AnyObject {
    /// Appends `batch` as the children of `parent`, records the folder, and
    /// returns the id of the first appended child.
    func appendChildren(of parent: UInt32, inode: UInt64, batch: ScanBatch) -> UInt32
}

// MARK: - Snapshot writer

final class SnapshotWriter: ScanSink {
    let directory: String
    private let folded, foldedOff, raw, rawOff, parent, mtime, ctime, size, flags: ColumnWriter
    private var dirs: [DirRecord] = []
    private(set) var count: UInt32 = 0
    private var files = 0, folders = 0

    init(directory: String) throws {
        self.directory = directory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func column(_ name: String) throws -> ColumnWriter {
            try ColumnWriter(path: (directory as NSString).appendingPathComponent(name))
        }
        folded = try column("folded.bin")
        foldedOff = try column("folded.off")
        raw = try column("raw.bin")
        rawOff = try column("raw.off")
        parent = try column("parent.u32")
        mtime = try column("mtime.u32")
        ctime = try column("ctime.u32")
        size = try column("size.u64")
        flags = try column("flags.u8")
    }

    @discardableResult
    func appendEntry(parent p: UInt32, raw r: UnsafeBufferPointer<UInt8>, folded f: UnsafeBufferPointer<UInt8>,
                     flags fl: UInt8, meta m: EntryMeta) -> UInt32 {
        foldedOff.append(UInt32(truncatingIfNeeded: folded.written))
        folded.append(f)
        folded.append(UInt8(0))
        rawOff.append(UInt32(truncatingIfNeeded: raw.written))
        raw.append(r)
        raw.append(UInt8(0))
        parent.append(p)
        mtime.append(m.mtime)
        ctime.append(m.ctime)
        size.append(m.size)
        flags.append(fl)
        if fl & EntryFlags.directory != 0 { folders += 1 } else { files += 1 }
        defer { count += 1 }
        return count
    }

    func appendDirectory(entry: UInt32, childStart: UInt32, childCount: UInt32, inode: UInt64) {
        dirs.append(DirRecord(entry: entry, childStart: childStart, childCount: childCount, inode: inode))
    }

    func appendChildren(of parent: UInt32, inode: UInt64, batch: ScanBatch) -> UInt32 {
        let start = count
        batch.forEachSorted { r, f, item in
            appendEntry(parent: parent, raw: r, folded: f, flags: item.flags, meta: item.meta)
        }
        appendDirectory(entry: parent, childStart: start, childCount: count - start, inode: inode)
        return start
    }

    func finish(meta: SnapshotMeta) throws {
        foldedOff.append(UInt32(truncatingIfNeeded: folded.written))
        rawOff.append(UInt32(truncatingIfNeeded: raw.written))
        guard folded.written < Int(UInt32.max), raw.written < Int(UInt32.max) else {
            throw StoreError.format("name arena exceeds 4 GB")
        }
        for column in [folded, foldedOff, raw, rawOff, parent, mtime, ctime, size, flags] {
            try column.finish()
        }
        dirs.sort { $0.entry < $1.entry }
        let dirsWriter = try ColumnWriter(path: (directory as NSString).appendingPathComponent("dirs.bin"))
        dirs.withUnsafeBytes { dirsWriter.append($0.baseAddress!, count: $0.count) }
        try dirsWriter.finish()
        let byInode = (0..<UInt32(dirs.count)).sorted { dirs[Int($0)].inode < dirs[Int($1)].inode }
        let inodeWriter = try ColumnWriter(path: (directory as NSString).appendingPathComponent("dirs.inode"))
        byInode.withUnsafeBytes { inodeWriter.append($0.baseAddress!, count: $0.count) }
        try inodeWriter.finish()
        var meta = meta
        meta.count = Int(count)
        meta.written = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("meta.json")))
        dirs = []
    }
}

// MARK: - Store

/// The catalog: a mapped snapshot (base) plus a small in-memory overlay of
/// changes (delta). Readers take the read lock; FSEvents reconciliation and
/// compaction run on the service's state queue under the write lock.
public final class IndexStore {
    private static let none = UInt32.max
    private static let emptyBytes: UnsafeMutableRawPointer = {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        p.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        return p
    }()

    // Base (mapped, clean pages)
    private var mapped: [MappedFile] = []
    private var bCount = 0
    private var bFolded = UnsafePointer<UInt8>(emptyBytes.assumingMemoryBound(to: UInt8.self))
    private var bRaw = UnsafePointer<UInt8>(emptyBytes.assumingMemoryBound(to: UInt8.self))
    private var bFoldedOff = UnsafePointer<UInt32>(emptyBytes.assumingMemoryBound(to: UInt32.self))
    private var bRawOff = UnsafePointer<UInt32>(emptyBytes.assumingMemoryBound(to: UInt32.self))
    private var bParent = UnsafePointer<UInt32>(emptyBytes.assumingMemoryBound(to: UInt32.self))
    private var bMtime = UnsafePointer<UInt32>(emptyBytes.assumingMemoryBound(to: UInt32.self))
    private var bCtime = UnsafePointer<UInt32>(emptyBytes.assumingMemoryBound(to: UInt32.self))
    private var bSize = UnsafePointer<UInt64>(emptyBytes.assumingMemoryBound(to: UInt64.self))
    private var bFlags = UnsafePointer<UInt8>(emptyBytes.assumingMemoryBound(to: UInt8.self))
    private var bDirs = UnsafePointer<DirRecord>(emptyBytes.assumingMemoryBound(to: DirRecord.self))
    private var bDirCount = 0
    private var bDirByInode = UnsafePointer<UInt32>(emptyBytes.assumingMemoryBound(to: UInt32.self))
    public private(set) var meta = SnapshotMeta()
    public private(set) var snapshotDirectory: String?

    // Delta (heap, small): entries appended after the snapshot.
    private let dFolded = GrowBuffer<UInt8>(capacity: 4096)
    private let dRaw = GrowBuffer<UInt8>(capacity: 4096)
    private let dFoldStart = GrowBuffer<UInt32>(), dFoldLen = GrowBuffer<UInt32>()
    private let dRawStart = GrowBuffer<UInt32>(), dRawLen = GrowBuffer<UInt32>()
    private let dParent = GrowBuffer<UInt32>()
    private let dMeta = GrowBuffer<EntryMeta>()
    private let dFlags = GrowBuffer<UInt8>()
    private var dInode: [UInt32: UInt64] = [:]
    private var inodeToDelta: [UInt64: UInt32] = [:]

    // Overlay on base ids.
    private let dead = Bitset()
    /// Base entries whose parent and/or name changed; they are listed through
    /// `added`, never through their original contiguous range.
    private let overridden = Bitset()
    private var parentOverride: [UInt32: UInt32] = [:]
    private var nameOverride: [UInt32: (foldStart: UInt32, foldLen: UInt32, rawStart: UInt32, rawLen: UInt32)] = [:]
    private let metaChanged = Bitset()
    private var metaOverride: [UInt32: EntryMeta] = [:]
    /// Children added to a folder after the snapshot (delta ids or moved base ids).
    private var added: [UInt32: [UInt32]] = [:]

    public private(set) var liveFiles = 0
    public private(set) var liveFolders = 0
    /// Mutations since the snapshot was written; drives compaction.
    public private(set) var pendingChanges = 0

    private let rw: UnsafeMutablePointer<pthread_rwlock_t> = {
        let p = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(p, nil)
        return p
    }()

    public init() {}

    deinit {
        pthread_rwlock_destroy(rw)
        rw.deallocate()
    }

    // MARK: Locking

    public func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(rw)
        defer { pthread_rwlock_unlock(rw) }
        return try body()
    }

    public func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(rw)
        defer { pthread_rwlock_unlock(rw) }
        return try body()
    }

    // MARK: Loading

    /// Maps the snapshot in `directory` and drops the delta. Caller holds the write lock
    /// (or the store is not shared yet).
    public func adopt(directory: String) throws {
        func map(_ name: String) throws -> MappedFile {
            try MappedFile(path: (directory as NSString).appendingPathComponent(name))
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("meta.json")))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(SnapshotMeta.self, from: data)
        guard meta.version == SnapshotMeta.formatVersion else { throw StoreError.format("version \(meta.version)") }

        let files = try ["folded.bin", "folded.off", "raw.bin", "raw.off", "parent.u32", "mtime.u32",
                         "ctime.u32", "size.u64", "flags.u8", "dirs.bin", "dirs.inode"].map(map)
        let n = meta.count
        guard files[1].count(of: UInt32.self) == n + 1, files[3].count(of: UInt32.self) == n + 1,
              files[4].count(of: UInt32.self) == n, files[5].count(of: UInt32.self) == n,
              files[6].count(of: UInt32.self) == n, files[7].count(of: UInt64.self) == n,
              files[8].length == n,
              files[9].count(of: DirRecord.self) == files[10].count(of: UInt32.self) else {
            throw StoreError.format("column sizes do not match count \(n)")
        }

        mapped = files
        bCount = n
        bFolded = files[0].typed(UInt8.self)
        bFoldedOff = files[1].typed(UInt32.self)
        bRaw = files[2].typed(UInt8.self)
        bRawOff = files[3].typed(UInt32.self)
        bParent = files[4].typed(UInt32.self)
        bMtime = files[5].typed(UInt32.self)
        bCtime = files[6].typed(UInt32.self)
        bSize = files[7].typed(UInt64.self)
        bFlags = files[8].typed(UInt8.self)
        bDirs = files[9].typed(DirRecord.self)
        bDirCount = files[9].count(of: DirRecord.self)
        bDirByInode = files[10].typed(UInt32.self)
        self.meta = meta
        snapshotDirectory = directory
        resetDelta()

        var folders = 0
        for i in 0..<n where bFlags[i] & EntryFlags.directory != 0 { folders += 1 }
        liveFolders = folders
        liveFiles = n - folders
    }

    private func resetDelta() {
        for buffer in [dFoldStart, dFoldLen, dRawStart, dRawLen, dParent] { buffer.removeAll() }
        dFolded.removeAll(); dRaw.removeAll(); dMeta.removeAll(); dFlags.removeAll()
        dInode = [:]; inodeToDelta = [:]
        parentOverride = [:]; nameOverride = [:]; metaOverride = [:]; added = [:]
        dead.clearAll(); overridden.clearAll(); metaChanged.clearAll()
        pendingChanges = 0
    }

    public func setEventId(_ id: UInt64) { meta.eventId = id }

    // MARK: Reading (caller holds a lock)

    public var count: Int { bCount + dFlags.count }
    public var baseCount: Int { bCount }
    public var rootCount: Int { meta.roots.count }

    /// Clean mapped bytes vs dirty overlay bytes (approximate).
    public var memoryReport: (mapped: Int, overlay: Int) {
        let m = mapped.reduce(0) { $0 + $1.length }
        let o = dFolded.bytes + dRaw.bytes + dFoldStart.bytes * 5 + dMeta.bytes + dFlags.bytes
            + dead.bytes + overridden.bytes + metaChanged.bytes
            + (dInode.count + parentOverride.count + nameOverride.count + metaOverride.count) * 48
            + added.values.reduce(0) { $0 + 48 + $1.count * 4 }
        return (m, o)
    }

    @inline(__always) public func isDead(_ i: Int) -> Bool { dead.test(i) }

    @inline(__always) public func flags(_ i: Int) -> UInt8 { i < bCount ? bFlags[i] : dFlags[i - bCount] }

    @inline(__always) public func isDirectory(_ i: Int) -> Bool { flags(i) & EntryFlags.directory != 0 }

    /// Parent id, or -1 for a root.
    @inline(__always) public func parent(_ i: Int) -> Int {
        let p: UInt32
        if i < bCount {
            p = overridden.test(i) ? (parentOverride[UInt32(i)] ?? bParent[i]) : bParent[i]
        } else {
            p = dParent[i - bCount]
        }
        return p == Self.none ? -1 : Int(p)
    }

    @inline(__always) public func folded(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        if i < bCount {
            if overridden.test(i), let o = nameOverride[UInt32(i)] {
                return UnsafeBufferPointer(start: dFolded.base + Int(o.foldStart), count: Int(o.foldLen))
            }
            let s = Int(bFoldedOff[i])
            return UnsafeBufferPointer(start: bFolded + s, count: Int(bFoldedOff[i + 1]) - s - 1)
        }
        let d = i - bCount
        return UnsafeBufferPointer(start: dFolded.base + Int(dFoldStart[d]), count: Int(dFoldLen[d]))
    }

    @inline(__always) public func raw(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        if i < bCount {
            if overridden.test(i), let o = nameOverride[UInt32(i)] {
                return UnsafeBufferPointer(start: dRaw.base + Int(o.rawStart), count: Int(o.rawLen))
            }
            let s = Int(bRawOff[i])
            return UnsafeBufferPointer(start: bRaw + s, count: Int(bRawOff[i + 1]) - s - 1)
        }
        let d = i - bCount
        return UnsafeBufferPointer(start: dRaw.base + Int(dRawStart[d]), count: Int(dRawLen[d]))
    }

    /// Name as stored in the base arena, ignoring renames: the sort key of a
    /// folder's contiguous child range.
    @inline(__always) private func baseFolded(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        let s = Int(bFoldedOff[i])
        return UnsafeBufferPointer(start: bFolded + s, count: Int(bFoldedOff[i + 1]) - s - 1)
    }

    /// True when the base name arena no longer describes entry `i` (renamed base entry).
    @inline(__always) public func hasNameOverride(_ i: Int) -> Bool {
        i < bCount && overridden.test(i) && nameOverride[UInt32(i)] != nil
    }

    @inline(__always) public func meta(_ i: Int) -> EntryMeta {
        if i < bCount {
            if metaChanged.test(i), let m = metaOverride[UInt32(i)] { return m }
            return EntryMeta(mtime: bMtime[i], ctime: bCtime[i], size: bSize[i])
        }
        return dMeta[i - bCount]
    }

    @inline(__always) public func mtime(_ i: Int) -> UInt32 {
        i < bCount && !metaChanged.test(i) ? bMtime[i] : meta(i).mtime
    }

    @inline(__always) public func size(_ i: Int) -> UInt64 {
        i < bCount && !metaChanged.test(i) ? bSize[i] : meta(i).size
    }

    /// Base arena for whole-arena scans: bytes, start offsets (count + 1 entries).
    public var baseArena: (bytes: UnsafePointer<UInt8>, offsets: UnsafePointer<UInt32>, count: Int) {
        (bFolded, bFoldedOff, bCount)
    }

    public func path(_ i: Int) -> String {
        var chain: [Int] = []
        var cursor = i
        while cursor >= 0 {
            chain.append(cursor)
            cursor = parent(cursor)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chain.count * 16)
        for (n, id) in chain.reversed().enumerated() {
            if n > 0, bytes.last != UInt8(ascii: "/") { bytes.append(UInt8(ascii: "/")) }
            bytes.append(contentsOf: raw(id))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Number of path components (matches `FileEntry.level`).
    public func depth(_ i: Int) -> Int {
        var steps = 0
        var cursor = i
        var root = i
        while cursor >= 0 {
            root = cursor
            cursor = parent(cursor)
            steps += 1
        }
        let rootComponents = raw(root).split(separator: UInt8(ascii: "/")).count
        return rootComponents + steps - 1
    }

    @inline(__always) private func dirIndex(_ id: Int) -> Int? {
        guard id < bCount else { return nil }
        var lo = 0, hi = bDirCount
        let key = UInt32(id)
        while lo < hi {
            let mid = (lo + hi) >> 1
            if bDirs[mid].entry < key { lo = mid + 1 } else { hi = mid }
        }
        return lo < bDirCount && bDirs[lo].entry == key ? lo : nil
    }

    /// Live children of a folder.
    public func children(of d: Int) -> [Int] {
        var out: [Int] = []
        if let di = dirIndex(d) {
            let record = bDirs[di]
            let start = Int(record.childStart)
            for c in start..<(start + Int(record.childCount)) where !dead.test(c) && !overridden.test(c) {
                out.append(c)
            }
        }
        if let extra = added[UInt32(d)] {
            var seen = Set<UInt32>()
            for c in extra where !dead.test(Int(c)) && parent(Int(c)) == d && seen.insert(c).inserted {
                out.append(Int(c))
            }
        }
        return out
    }

    public func inode(ofDirectory d: Int) -> UInt64? {
        if let di = dirIndex(d) { return bDirs[di].inode }
        return dInode[UInt32(d)]
    }

    /// Live folder with this inode, if any.
    public func directory(withInode inode: UInt64) -> Int? {
        if let d = inodeToDelta[inode], !dead.test(Int(d)) { return Int(d) }
        var lo = 0, hi = bDirCount
        while lo < hi {
            let mid = (lo + hi) >> 1
            if bDirs[Int(bDirByInode[mid])].inode < inode { lo = mid + 1 } else { hi = mid }
        }
        while lo < bDirCount, bDirs[Int(bDirByInode[lo])].inode == inode {
            let id = Int(bDirs[Int(bDirByInode[lo])].entry)
            if !dead.test(id) { return id }
            lo += 1
        }
        return nil
    }

    /// Child of folder `d` named `name` (exact raw match preferred, folded fallback).
    public func child(of d: Int, named name: String) -> Int? {
        let rawName = Array(name.utf8)
        let key = Fold.fold(name)
        var foldedMatch: Int?
        if let di = dirIndex(d) {
            let record = bDirs[di]
            var lo = Int(record.childStart), hi = lo + Int(record.childCount)
            let end = hi
            key.withUnsafeBufferPointer { k in
                while lo < hi {
                    let mid = (lo + hi) >> 1
                    if Self.compare(baseFolded(mid), k) < 0 { lo = mid + 1 } else { hi = mid }
                }
            }
            var c = lo
            while c < end, key.withUnsafeBufferPointer({ Self.compare(baseFolded(c), $0) == 0 }) {
                if !dead.test(c) && !overridden.test(c) {
                    if Self.equal(raw(c), rawName) { return c }
                    if foldedMatch == nil { foldedMatch = c }
                }
                c += 1
            }
        }
        if let extra = added[UInt32(d)] {
            for c in extra.reversed() where !dead.test(Int(c)) && parent(Int(c)) == d {
                if Self.equal(raw(Int(c)), rawName) { return Int(c) }
                if foldedMatch == nil, key.withUnsafeBufferPointer({ Self.compare(folded(Int(c)), $0) == 0 }) {
                    foldedMatch = Int(c)
                }
            }
        }
        return foldedMatch
    }

    /// Id of the entry at an absolute path, if indexed.
    public func resolve(_ path: String) -> Int? {
        for r in 0..<rootCount where !dead.test(r) {
            let root = meta.roots[r]
            guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { continue }
            var cursor = r
            let rest = path.dropFirst(root.count)
            for component in rest.split(separator: "/") {
                guard let next = child(of: cursor, named: String(component)) else { return nil }
                cursor = next
            }
            return cursor
        }
        return nil
    }

    // MARK: Writing (caller holds the write lock)

    @discardableResult
    public func appendDelta(parent p: Int, raw r: UnsafeBufferPointer<UInt8>, folded f: UnsafeBufferPointer<UInt8>,
                            flags fl: UInt8, meta m: EntryMeta, inode: UInt64) -> Int {
        let id = count
        dFoldStart.append(UInt32(dFolded.count)); dFoldLen.append(UInt32(f.count)); dFolded.append(contentsOf: f)
        dRawStart.append(UInt32(dRaw.count)); dRawLen.append(UInt32(r.count)); dRaw.append(contentsOf: r)
        dParent.append(p < 0 ? Self.none : UInt32(p))
        dMeta.append(m)
        dFlags.append(fl)
        if fl & EntryFlags.directory != 0 {
            dInode[UInt32(id)] = inode
            inodeToDelta[inode] = UInt32(id)
            liveFolders += 1
        } else {
            liveFiles += 1
        }
        if p >= 0 { added[UInt32(p), default: []].append(UInt32(id)) }
        pendingChanges += 1
        return id
    }

    public func setMeta(_ i: Int, _ m: EntryMeta) {
        guard meta(i) != m else { return }
        if i < bCount {
            metaOverride[UInt32(i)] = m
            metaChanged.set(i)
        } else {
            dMeta[i - bCount] = m
        }
        pendingChanges += 1
    }

    /// Marks `i` and everything below it dead.
    public func removeSubtree(_ i: Int) {
        var stack = [i]
        while let id = stack.popLast() {
            guard !dead.test(id) else { continue }
            if isDirectory(id) {
                stack.append(contentsOf: children(of: id))
                liveFolders -= 1
            } else {
                liveFiles -= 1
            }
            dead.set(id)
            if id >= bCount, let inode = dInode[UInt32(id)], inodeToDelta[inode] == UInt32(id) {
                inodeToDelta[inode] = nil
            }
            pendingChanges += 1
        }
    }

    /// Moves/renames entry `i` under `p`. The subtree is untouched: children keep
    /// pointing at `i`.
    public func move(_ i: Int, to p: Int, raw r: UnsafeBufferPointer<UInt8>, folded f: UnsafeBufferPointer<UInt8>) {
        if i < bCount {
            parentOverride[UInt32(i)] = UInt32(p)
            if !Self.equal(raw(i), Array(r)) {
                let fs = UInt32(dFolded.count), rs = UInt32(dRaw.count)
                dFolded.append(contentsOf: f)
                dRaw.append(contentsOf: r)
                nameOverride[UInt32(i)] = (fs, UInt32(f.count), rs, UInt32(r.count))
            }
            overridden.set(i)
        } else {
            let d = i - bCount
            dParent[d] = UInt32(p)
            dFoldStart[d] = UInt32(dFolded.count); dFoldLen[d] = UInt32(f.count); dFolded.append(contentsOf: f)
            dRawStart[d] = UInt32(dRaw.count); dRawLen[d] = UInt32(r.count); dRaw.append(contentsOf: r)
        }
        added[UInt32(p), default: []].append(UInt32(i))
        pendingChanges += 1
    }

    // MARK: Compaction

    /// Writes the live tree as a new snapshot (breadth-first, children sorted), streaming
    /// straight to disk. Caller holds at least the read lock and blocks mutations.
    public func writeSnapshot(to directory: String, meta newMeta: SnapshotMeta) throws {
        let writer = try SnapshotWriter(directory: directory)
        var queue: [(old: Int, new: UInt32)] = []
        for r in 0..<rootCount where !dead.test(r) {
            let id = writer.appendEntry(parent: Self.none, raw: raw(r), folded: folded(r), flags: flags(r), meta: meta(r))
            queue.append((r, id))
        }
        var head = 0
        while head < queue.count {
            let (old, new) = queue[head]
            head += 1
            let kids = children(of: old).sorted { a, b in
                let c = Self.compare(folded(a), folded(b))
                return c != 0 ? c < 0 : Self.compare(raw(a), raw(b)) < 0
            }
            let start = writer.count
            for k in kids {
                let id = writer.appendEntry(parent: new, raw: raw(k), folded: folded(k), flags: flags(k), meta: meta(k))
                if isDirectory(k) { queue.append((k, id)) }
            }
            writer.appendDirectory(entry: new, childStart: start, childCount: writer.count - start,
                                   inode: inode(ofDirectory: old) ?? 0)
            if head > 4096 {
                queue.removeFirst(head)
                head = 0
            }
        }
        var m = newMeta
        m.roots = meta.roots
        try writer.finish(meta: m)
    }

    // MARK: Helpers

    @inline(__always) static func compare(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        let n = min(a.count, b.count)
        if n > 0, let pa = a.baseAddress, let pb = b.baseAddress {
            let c = memcmp(pa, pb, n)
            if c != 0 { return Int(c) }
        }
        return a.count - b.count
    }

    @inline(__always) static func equal(_ a: UnsafeBufferPointer<UInt8>, _ b: [UInt8]) -> Bool {
        b.withUnsafeBufferPointer { compare(a, $0) == 0 }
    }
}
