import Foundation
import CoreServices

/// One FSEvents record.
public struct ChangeEvent: Sendable {
    public var path: String
    public var flags: FSEventStreamEventFlags
    public var id: FSEventStreamEventId

    public func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }

    /// The kernel or the client dropped events, ids wrapped, or a root moved:
    /// incremental state can no longer be trusted.
    public var requiresFullRescan: Bool {
        has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
            || has(kFSEventStreamEventFlagEventIdsWrapped) || has(kFSEventStreamEventFlagRootChanged)
    }

    public var mustScanSubdirectories: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) }
    public var isHistoryDone: Bool { has(kFSEventStreamEventFlagHistoryDone) }
}

private func quollFSEventsCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let monitor = Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    var events: [ChangeEvent] = []
    events.reserveCapacity(numEvents)
    for i in 0..<min(numEvents, paths.count) {
        events.append(ChangeEvent(path: paths[i], flags: eventFlags[i], id: eventIds[i]))
    }
    monitor.receive(events)
}

/// Watches the roots with FSEvents and delivers debounced batches of events.
///
/// Started with `sinceWhen` = the snapshot's event id, the stream first replays
/// everything that changed while Quoll was not running, then `HistoryDone`.
public final class ChangeWatcher {
    private let paths: [String]
    private let sinceWhen: FSEventStreamEventId
    private let latency: TimeInterval
    private let debounce: TimeInterval
    private let callback: ([ChangeEvent]) -> Void
    private let queue = DispatchQueue(label: "quoll.watch")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pending: [ChangeEvent] = []
    private var workItem: DispatchWorkItem?

    public init(
        paths: [String],
        sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency: TimeInterval = 1.0,
        debounce: TimeInterval = 0.5,
        callback: @escaping ([ChangeEvent]) -> Void
    ) {
        self.paths = paths
        self.sinceWhen = sinceWhen
        self.latency = latency
        self.debounce = debounce
        self.callback = callback
    }

    deinit { stop() }

    public static var currentEventId: FSEventStreamEventId { FSEventsGetCurrentEventId() }

    /// FSEvents volume UUID for the device holding `path` (empty if unknown).
    public static func volumeUUID(for path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return "" }
        return (CFUUIDCreateString(nil, uuid) as String?) ?? ""
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            quollFSEventsCallback,
            &context,
            existing as CFArray,
            sinceWhen,
            latency,
            flags
        ) else {
            throw NSError(domain: "Quoll.FSEvents", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unable to create FSEvents stream"])
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw NSError(domain: "Quoll.FSEvents", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unable to start FSEvents stream"])
        }
        stream = created
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        workItem?.cancel()
        workItem = nil
        lock.unlock()

        if let current {
            FSEventStreamStop(current)
            FSEventStreamInvalidate(current)
            FSEventStreamRelease(current)
        }
    }

    fileprivate func receive(_ events: [ChangeEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: events)
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        workItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        workItem = nil
        lock.unlock()
        if !batch.isEmpty { callback(batch) }
    }
}
