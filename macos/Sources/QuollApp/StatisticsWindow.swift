import AppKit
import QuollCore

/// Index statistics: totals, largest folders, file types by size. Computed on
/// demand in the background; nothing is kept once the window is closed.
final class StatisticsWindow: NSWindow {
    private let text = NSTextView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        title = "Index Statistics"
        isReleasedWhenClosed = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.autoresizingMask = [.width]
        contentView = scroll
        center()
    }

    func load(from backend: SearchBackend) {
        text.string = "Computing…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = backend.statistics().map(Self.render) ?? "Statistics are available when the app hosts the index."
            DispatchQueue.main.async { self?.text.string = report }
        }
    }

    private static func render(_ s: QuollService.Statistics) -> String {
        func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
        let home = NSHomeDirectory()
        func short(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
        var lines = [
            "Indexed      \(s.files.formatted()) files, \(s.folders.formatted()) folders",
            "Snapshot     \(ByteCountFormatter.string(fromByteCount: s.snapshotBytes, countStyle: .file)) on disk",
            "", "Largest folders", ""
        ]
        for f in s.largest {
            lines.append("  " + size(f.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)
                         + "\(f.files.formatted()) files".padding(toLength: 16, withPad: " ", startingAt: 0) + short(f.path))
        }
        lines += ["", "File types by size", ""]
        for t in s.types {
            lines.append("  " + size(t.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)
                         + "\(t.count.formatted()) files".padding(toLength: 16, withPad: " ", startingAt: 0) + "." + t.ext)
        }
        return lines.joined(separator: "\n")
    }
}
