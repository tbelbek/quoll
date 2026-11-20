import Foundation

// Low-level building blocks for the column store: name folding, growable
// buffers, bitsets, buffered column writers and read-only mapped files.

// MARK: - Folding

/// Name folding used for every case-insensitive comparison: NFD, strip combining
/// marks, lowercase, dotless `ı` → `i`. Locale-independent, so `İ I ı i` all fold
/// to `i`. Applied once per name at index time and once per query.
public enum Fold {
    /// Appends the folded form of `bytes` (UTF-8) to `out`.
    @inline(__always)
    public static func append(_ bytes: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) {
        var ascii = true
        for b in bytes where b >= 0x80 { ascii = false; break }
        if ascii {
            for b in bytes { out.append(b >= 65 && b <= 90 ? b | 0x20 : b) }
            return
        }
        out.append(contentsOf: slow(String(decoding: bytes, as: UTF8.self)).utf8)
    }

    public static func fold(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        var copy = string
        copy.withUTF8 { append($0, to: &out) }
        return out
    }

    private static func slow(_ string: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in string.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars).lowercased().replacingOccurrences(of: "ı", with: "i")
    }
}

// MARK: - Growable buffer (stable class identity, manual storage)

final class GrowBuffer<T> {
    private(set) var base: UnsafeMutablePointer<T>
    private(set) var count = 0
    private var capacity: Int

    init(capacity: Int = 64) {
        self.capacity = max(capacity, 1)
        base = .allocate(capacity: self.capacity)
    }

    deinit { base.deallocate() }

    @inline(__always) subscript(i: Int) -> T {
        get { base[i] }
        set { base[i] = newValue }
    }

    @inline(__always) func append(_ value: T) {
        if count == capacity { grow(to: count + 1) }
        (base + count).initialize(to: value)
        count += 1
    }

    func append(contentsOf buffer: UnsafeBufferPointer<T>) {
        guard let source = buffer.baseAddress, buffer.count > 0 else { return }
        if count + buffer.count > capacity { grow(to: count + buffer.count) }
        (base + count).initialize(from: source, count: buffer.count)
        count += buffer.count
    }

    func removeAll() { count = 0 }

    var bytes: Int { count * MemoryLayout<T>.stride }

    private func grow(to needed: Int) {
        // 1.5x growth keeps the realloc slack (dirty memory) small.
        var next = capacity
        while next < needed { next += max(next / 2, 64) }
        let fresh = UnsafeMutablePointer<T>.allocate(capacity: next)
        fresh.moveInitialize(from: base, count: count)
        base.deallocate()
        base = fresh
        capacity = next
    }
}

// MARK: - Bitset

final class Bitset {
    private var words: [UInt64]

    init(count: Int = 0) { words = Array(repeating: 0, count: (count + 63) / 64) }

    @inline(__always) func test(_ i: Int) -> Bool {
        let w = i >> 6
        return w < words.count && words[w] & (1 << UInt64(i & 63)) != 0
    }

    @inline(__always) func set(_ i: Int) {
        let w = i >> 6
        if w >= words.count { words.append(contentsOf: repeatElement(0, count: w - words.count + 1 + words.count / 8)) }
        words[w] |= 1 << UInt64(i & 63)
    }

    @inline(__always) func clear(_ i: Int) {
        let w = i >> 6
        if w < words.count { words[w] &= ~(1 << UInt64(i & 63)) }
    }

    var bytes: Int { words.count * 8 }

    func clearAll() { words = [] }
}

// MARK: - Read-only mapped file

/// A whole file mapped read-only. Its pages are clean and file-backed, so they do
/// not count toward the process footprint and the kernel may drop them under
/// memory pressure instead of swapping. Never truncate a mapped file in place:
/// replacements are written to a new file and renamed (SIGBUS otherwise).
final class MappedFile {
    let pointer: UnsafeRawPointer
    let length: Int
    private let mapped: Bool

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw StoreError.io("open \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw StoreError.io("stat \(path)") }
        length = Int(st.st_size)
        if length == 0 {
            pointer = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16))
            mapped = false
            return
        }
        guard let p = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw StoreError.io("mmap \(path): \(String(cString: strerror(errno)))")
        }
        pointer = UnsafeRawPointer(p)
        mapped = true
    }

    deinit {
        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: pointer), length)
        } else {
            UnsafeMutableRawPointer(mutating: pointer).deallocate()
        }
    }

    func typed<T>(_: T.Type) -> UnsafePointer<T> { pointer.assumingMemoryBound(to: T.self) }
    func count<T>(of _: T.Type) -> Int { length / MemoryLayout<T>.stride }
}

// MARK: - Buffered column writer

/// Appends to a file through a 256 KB buffer, so writing a snapshot never holds
/// a column in memory.
final class ColumnWriter {
    private let fd: Int32
    private let buffer: UnsafeMutableRawPointer
    private let capacity = 256 * 1024
    private var used = 0
    private(set) var written = 0
    let path: String

    init(path: String) throws {
        self.path = path
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw StoreError.io("create \(path): \(String(cString: strerror(errno)))") }
        buffer = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        buffer.deallocate()
        if fd >= 0 { close(fd) }
    }

    @inline(__always) func append(_ source: UnsafeRawPointer, count: Int) {
        if used + count > capacity { flush() }
        if count > capacity {
            writeAll(source, count)
            return
        }
        (buffer + used).copyMemory(from: source, byteCount: count)
        used += count
        written += count
    }

    @inline(__always) func append<T>(_ value: T) {
        withUnsafeBytes(of: value) { append($0.baseAddress!, count: $0.count) }
    }

    func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        if let base = bytes.baseAddress, bytes.count > 0 { append(base, count: bytes.count) }
    }

    func finish() throws {
        flush()
        guard fsync(fd) == 0 else { throw StoreError.io("fsync \(path)") }
    }

    private func flush() {
        if used > 0 { writeAll(buffer, used, countWritten: false) }
        used = 0
    }

    private func writeAll(_ source: UnsafeRawPointer, _ count: Int, countWritten: Bool = true) {
        var offset = 0
        while offset < count {
            let n = write(fd, source + offset, count - offset)
            if n < 0 { if errno == EINTR { continue }; break }
            offset += n
        }
        if countWritten { written += count }
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case io(String)
    case format(String)

    public var description: String {
        switch self {
        case .io(let m): return "I/O: \(m)"
        case .format(let m): return "snapshot: \(m)"
        }
    }
}

// MARK: - Process footprint

public enum Footprint {
    /// Current and peak `phys_footprint` in bytes (what Activity Monitor calls
    /// Memory): dirty + compressed memory, excluding clean file-backed pages.
    public static func current() -> (now: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak))
    }
}
