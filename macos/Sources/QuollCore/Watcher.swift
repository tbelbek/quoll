import Foundation
import CoreServices

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
    monitor.receive(paths)
}

/// Watches scanned roots with FSEvents and debounces batches of changed paths.
public final class ChangeWatcher {
    private let paths: [String]
    private let latency: TimeInterval
    private let debounce: TimeInterval
    private let callback: ([String]) -> Void
    private let queue = DispatchQueue(label: "quoll.watch")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var workItem: DispatchWorkItem?

    public init(
        paths: [String],
        latency: TimeInterval = 0.3,
        debounce: TimeInterval = 0.8,
        callback: @escaping ([String]) -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.debounce = debounce
        self.callback = callback
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
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            quollFSEventsCallback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw NSError(
                domain: "Quoll.FSEvents",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unable to create FSEvents stream"]
            )
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw NSError(
                domain: "Quoll.FSEvents",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unable to start FSEvents stream"]
            )
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

    fileprivate func receive(_ changed: [String]) {
        guard !changed.isEmpty else { return }
        lock.lock()
        pending.formUnion(changed)
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        workItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func flush() {
        lock.lock()
        let changed = pending.sorted()
        pending.removeAll()
        workItem = nil
        lock.unlock()

        if !changed.isEmpty {
            callback(changed)
        }
    }
}
