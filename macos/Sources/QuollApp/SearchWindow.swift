import AppKit
import Quartz
import UniformTypeIdentifiers
import QuollCore

/// Where searches go: the in-process service (normal) or a separately running
/// `quoll serve` over the control socket.
protocol SearchBackend: AnyObject {
    func search(_ options: QueryOptions, interactive: Bool) -> QueryResult?
    func status() -> CatalogStatus?
    func rebuild()
}

final class InProcessBackend: SearchBackend {
    let service: QuollService
    init(service: QuollService) { self.service = service }

    func search(_ options: QueryOptions, interactive: Bool) -> QueryResult? {
        service.engine.search(options, in: service.store, cancellable: interactive)
    }

    func status() -> CatalogStatus? { service.status() }
    func rebuild() { service.rebuild() }
}

final class SocketBackend: SearchBackend {
    let client: ControlClient
    init(client: ControlClient) { self.client = client }

    func search(_ options: QueryOptions, interactive: Bool) -> QueryResult? {
        guard let reply = try? client.send(ControlRequest(command: "search", query: options.query, limit: options.limit,
                                                          offset: options.offset, sort: options.sort,
                                                          ascending: options.ascending)), reply.ok else { return nil }
        var result = QueryResult(query: options.query, count: reply.count ?? 0, total: reply.total ?? 0,
                                 tookMS: reply.tookMS ?? 0, truncated: false, results: reply.results ?? [])
        result.warnings = reply.warnings ?? []
        return result
    }

    func status() -> CatalogStatus? { (try? client.send(ControlRequest(command: "status")))?.status }
    func rebuild() { _ = try? client.send(ControlRequest(command: "rebuild")) }
}

/// The search window: a normal titled window (movable, resizable, full screen
/// via the green button or ⌃⌘F) that the hotkey shows and hides. The app stays
/// an accessory app: no Dock icon, no ⌘Tab entry.
final class SearchPanel: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?

    /// Esc anywhere in the window (field, table, header) hides it.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: true)
        title = "Quoll"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 240)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class SearchController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                              NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate,
                              QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let backend: SearchBackend
    private let queue = DispatchQueue(label: "quoll.app.search", qos: .userInitiated)
    private lazy var pager = ResultPager { [weak self] options, interactive, isCurrent, reply in
        guard let self else { return }
        self.queue.async {
            // Typing fast queues searches; only the newest one is worth running.
            guard isCurrent() else { DispatchQueue.main.async { reply(nil) }; return }
            let result = self.backend.search(options, interactive: interactive)
            DispatchQueue.main.async { reply(result) }
        }
    }

    private let field = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private var iconCache: [String: NSImage] = [:]
    /// Literal pieces of the current query, shown in bold inside names.
    private var highlights: [String] = []
    private var indexed = 0
    var onHide: (() -> Void)?
    var onSettings: (() -> Void)?

    private static let home = NSHomeDirectory()
    private let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    init(backend: SearchBackend) {
        self.backend = backend
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        // Large control (28 pt) with the standard 13 pt font: a bigger font in a
        // regular field clips descenders (measured with an offscreen render).
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.placeholderAttributedString = NSAttributedString(
            string: "Search  —  *.pdf, ending:md, changed:today, under:Repos",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        func column(_ id: String, _ title: String, width: CGFloat, sortKey: String?, alignRight: Bool = false) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 60
            if alignRight { c.headerCell.alignment = .right }
            if let sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: sortKey == "name") }
            table.addTableColumn(c)
        }
        column("name", "Name", width: 300, sortKey: "name")
        column("folder", "Folder", width: 360, sortKey: nil)
        column("size", "Size", width: 80, sortKey: "size", alignRight: true)
        column("modified", "Modified", width: 130, sortKey: "modified")
        column("created", "Created", width: 130, sortKey: "created")
        // Not sortable: an extension sort collects every match (2.3M on an empty query).
        column("kind", "Kind", width: 70, sortKey: nil)
        for id in ["created", "kind"] {
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.isHidden = true
        }
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        table.sortDescriptors = [NSSortDescriptor(key: "modified", ascending: false)]
        table.style = .fullWidth
        table.rowHeight = 20
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.menu = contextMenu()
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.autosaveName = "QuollResults"
        table.autosaveTableColumns = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for label in [statusLabel, warningLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        warningLabel.textColor = .systemOrange
        warningLabel.alignment = .right

        root.addSubview(field)
        root.addSubview(scroll)
        root.addSubview(statusLabel)
        root.addSubview(warningLabel)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 32),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            warningLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            warningLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            warningLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        view = root

        pager.onReset = { [weak self] in self?.resultsReset() }
        pager.onRows = { [weak self] rows in
            guard let self else { return }
            self.table.reloadData(forRowIndexes: IndexSet(integersIn: rows),
                                  columnIndexes: IndexSet(integersIn: 0..<self.table.numberOfColumns))
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelection), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelection), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPaths), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Name", action: #selector(copyNames), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Show / hide

    func willShow() {
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        refreshIndexCount()
        runSearch()
    }

    func setQuery(_ query: String) {
        field.stringValue = query
        runSearch()
    }

    func didHide() {
        closeQuickLook()
        pager.dropCache()
        table.reloadData()
    }

    private func refreshIndexCount() {
        queue.async { [weak self] in
            guard let status = self?.backend.status() else { return }
            DispatchQueue.main.async {
                self?.indexed = status.files + status.directories
                self?.updateStatus()
            }
        }
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { runSearch() }

    private func runSearch() {
        let descriptor = table.sortDescriptors.first
        let sort: SortKey
        switch descriptor?.key {
        case "name": sort = .name
        case "size": sort = .size
        case "created": sort = .created
        default: sort = .modified
        }
        highlights = Self.highlightPieces(field.stringValue)
        pager.search(field.stringValue, sort: sort, ascending: descriptor?.ascending ?? false)
    }

    private func resultsReset() {
        table.reloadData()
        if pager.rowCount > 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateStatus()
    }

    private func updateStatus() {
        var text = "\(pager.total.formatted()) results · \(String(format: "%.1f", pager.tookMS)) ms"
        if pager.isCapped { text += " · showing first \(pager.cap.formatted())" }
        text += indexed > 0 ? " · \(indexed.formatted()) indexed" : " · indexing…"
        statusLabel.stringValue = text
        warningLabel.stringValue = pager.warnings.filter { $0 != "cancelled" }.joined(separator: "  ")
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        runSearch()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { pager.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        guard let entry = pager.entry(at: row) else {
            cell.textField?.stringValue = ""
            cell.imageView?.image = nil
            return cell
        }
        switch id.rawValue {
        case "name":
            cell.textField?.attributedStringValue = highlighted(entry.name)
            cell.imageView?.image = icon(for: entry)
        case "created":
            let formatter = Calendar.current.isDateInToday(entry.created) ? timeFormatter : dateFormatter
            cell.textField?.stringValue = formatter.string(from: entry.created)
        case "kind":
            cell.textField?.stringValue = entry.isDirectory ? "folder" : entry.fileExtension
        case "folder":
            let folder = (entry.path as NSString).deletingLastPathComponent
            cell.textField?.stringValue = folder.hasPrefix(Self.home) ? "~" + folder.dropFirst(Self.home.count) : folder
        case "size":
            cell.textField?.stringValue = entry.isDirectory ? "–" : entry.formattedSize
        default:
            let formatter = Calendar.current.isDateInToday(entry.modified) ? timeFormatter : dateFormatter
            cell.textField?.stringValue = formatter.string(from: entry.modified)
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 13)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = id.rawValue == "folder" ? .byTruncatingHead : .byTruncatingTail
        if id.rawValue == "size" { text.alignment = .right }
        if id.rawValue != "name" { text.textColor = .secondaryLabelColor }
        cell.addSubview(text)
        cell.textField = text
        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16)
            ])
            leading = text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5)
        }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: Highlighting

    /// Plain words of the query (no filters, negations or wildcards) to bold in names.
    static func highlightPieces(_ query: String) -> [String] {
        var pieces: [String] = []
        for token in query.split(whereSeparator: { $0 == " " || $0 == "|" || $0 == "(" || $0 == ")" }) {
            var word = String(token).replacingOccurrences(of: "\"", with: "")
            if word.hasPrefix("!") || word.hasPrefix("-") { continue }
            if let colon = word.firstIndex(of: ":") {
                let filter = word[..<colon].lowercased()
                guard ["starts", "ends", "exact", "word", "leaf", "icase", "matchcase"].contains(filter) else { continue }
                word = String(word[word.index(after: colon)...])
            }
            pieces += word.split(whereSeparator: { $0 == "*" || $0 == "?" }).map(String.init).filter { !$0.isEmpty }
        }
        return pieces.sorted { $0.count > $1.count }
    }

    private func highlighted(_ name: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        // labelColor is dynamic: follows light/dark and stays readable in selected rows.
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        let ns = name as NSString
        let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
        for piece in highlights {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: piece, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                if found.location == NSNotFound || found.length == 0 { break }
                text.addAttribute(.font, value: bold, range: found)
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return text
    }

    // MARK: Column chooser (header right-click)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in table.tableColumns where column.identifier.rawValue != "name" {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
        if !column.isHidden { table.reloadData() }
    }

    // MARK: Quick Look (⌘Y)

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func closeQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedEntries.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let entries = selectedEntries
        guard index < entries.count else { return nil }
        return URL(fileURLWithPath: entries[index].path) as NSURL
    }

    /// ↑/↓ while the preview is key move the selection in the table.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1, extend: false); return true
        case 126: moveSelection(by: -1, extend: false); return true
        default: return false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    /// One icon per extension (plus folder), never per file: no disk access.
    private func icon(for entry: FileEntry) -> NSImage {
        let key = entry.isDirectory ? "/" : entry.fileExtension
        if let cached = iconCache[key] { return cached }
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        pager.entry(at: row).map { NSURL(fileURLWithPath: $0.path) }
    }

    // MARK: Actions

    private var selectedEntries: [FileEntry] {
        var rows = table.selectedRowIndexes
        if table.clickedRow >= 0, !rows.contains(table.clickedRow) { rows = IndexSet(integer: table.clickedRow) }
        return rows.compactMap { pager.entry(at: $0) }
    }

    @objc func openSelection() {
        let urls = selectedEntries.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        urls.forEach { NSWorkspace.shared.open($0) }
        onHide?()
    }

    @objc func revealSelection() {
        let urls = selectedEntries.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        onHide?()
    }

    @objc func copyPaths() { copy(selectedEntries.map(\.path)) }
    @objc func copyNames() { copy(selectedEntries.map(\.name)) }

    private func copy(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func reindex() {
        indexed = 0
        updateStatus()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.backend.rebuild()
            DispatchQueue.main.async { self?.refreshIndexCount(); self?.runSearch() }
        }
    }

    // MARK: Keyboard

    /// Keys typed in the search field that drive the table (focus never moves).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1, extend: false)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1, extend: false)
        case #selector(NSResponder.moveUpAndModifySelection(_:)): moveSelection(by: -1, extend: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)): moveSelection(by: 1, extend: true)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): moveSelection(by: -visibleRows, extend: false)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): moveSelection(by: visibleRows, extend: false)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): select(row: 0)
        case #selector(NSResponder.moveToEndOfDocument(_:)): select(row: pager.rowCount - 1)
        case #selector(NSResponder.insertNewline(_:)): openSelection()
        case #selector(NSResponder.cancelOperation(_:)): onHide?()
        default: return false
        }
        return true
    }

    private var visibleRows: Int { max(1, Int(scroll.contentView.bounds.height / table.rowHeight) - 1) }

    private func moveSelection(by delta: Int, extend: Bool) {
        guard pager.rowCount > 0 else { return }
        let current = delta < 0 ? (table.selectedRowIndexes.first ?? 0) : (table.selectedRowIndexes.last ?? -1)
        let target = min(max(0, current + delta), pager.rowCount - 1)
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: extend)
        table.scrollRowToVisible(target)
    }

    private func select(row: Int) {
        guard row >= 0, row < pager.rowCount else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Window-level shortcuts; returns true when handled.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key, event.keyCode) {
        case (.command, _, 36), (.command, _, 76):            // ⌘Return / ⌘Enter
            revealSelection()
        case (.command, "c", _):
            // A text selection in the field copies text; otherwise copy paths.
            if let editor = field.currentEditor(), editor.selectedRange.length > 0 { return false }
            copyPaths()
        case ([.command, .option], "c", _): copyNames()
        case (.command, "l", _):
            view.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        case (.command, "r", _): reindex()
        case (.command, "y", _): toggleQuickLook()
        case (.command, "w", _): onHide?()
        case (.command, ",", _): onSettings?()
        default: return false
        }
        return true
    }
}
