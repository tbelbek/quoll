import AppKit
import QuollCore
import ServiceManagement

/// Minimal settings: hotkey, roots, excludes, includes, default excludes.
/// One rule per line; Save applies them (a rescan when roots or rules changed).
final class SettingsWindow: NSWindow {
    private let hotkeyField = NSTextField()
    private let hotkeyNote = NSTextField(labelWithString: "")
    private let roots = SettingsWindow.textArea()
    private let excludes = SettingsWindow.textArea()
    private let includes = SettingsWindow.textArea()
    private let defaults = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let atLogin = NSButton(checkboxWithTitle: "Open Quoll at login", target: nil, action: nil)
    private let loginNote = NSTextField(labelWithString: "")
    private let onSave: (Preferences) -> Void
    private var base: Preferences

    init(settings: Preferences, onSave: @escaping (Preferences) -> Void) {
        self.onSave = onSave
        base = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        title = "Quoll Settings"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 460, height: 480)
        defaults.title = "Use default excludes: " + ExcludeRules.defaults.joined(separator: ", ")
        defaults.lineBreakMode = .byWordWrapping
        hotkeyField.placeholderString = "hyper+s"
        hotkeyNote.font = .systemFont(ofSize: 11)
        hotkeyNote.textColor = .secondaryLabelColor

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .boldSystemFont(ofSize: 12)
            return l
        }
        func hint(_ text: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal

        loginNote.font = .systemFont(ofSize: 11)
        loginNote.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            atLogin, loginNote,
            label("Global hotkey"), hotkeyField,
            hint("e.g. super+s (⌃⌥⌘S), hyper+s (⌃⌥⇧⌘S), control+option+space, cmd+shift+f"), hotkeyNote,
            label("Folders to index (one per line)"), roots.scroll,
            label("Exclude (one per line)"), excludes.scroll,
            hint("A name (node_modules, *.tmp) matches at any depth; a path (~/Downloads/old) excludes that folder."),
            defaults,
            label("Always include (one per line)"), includes.scroll,
            hint("Overrides any exclude, e.g. ~/Library/Caches/com.example or node_modules."),
            buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [hotkeyField, roots.scroll, excludes.scroll, includes.scroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        roots.scroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        excludes.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        includes.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        contentView = content
        center()
    }

    func load(_ settings: Preferences) {
        base = settings
        hotkeyField.stringValue = settings.hotkey
        hotkeyNote.stringValue = ""
        roots.text.string = settings.roots.joined(separator: "\n")
        excludes.text.string = settings.excludes.joined(separator: "\n")
        includes.text.string = settings.includes.joined(separator: "\n")
        defaults.state = settings.useDefaultExcludes ? .on : .off
        refreshLoginState()
    }

    /// Login item through SMAppService (macOS 13+): the system lists it under
    /// System Settings › General › Login Items, where the user can also remove it.
    private func refreshLoginState() {
        let status = SMAppService.mainApp.status
        atLogin.state = status == .enabled ? .on : .off
        switch status {
        case .requiresApproval:
            loginNote.stringValue = "Waiting for approval in System Settings › General › Login Items."
        case .notFound:
            loginNote.stringValue = "Move Quoll to /Applications to open it at login."
        default:
            loginNote.stringValue = ""
        }
    }

    private func applyLogin() {
        let wanted = atLogin.state == .on
        let enabled = SMAppService.mainApp.status == .enabled
        guard wanted != enabled else { return }
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginNote.stringValue = "Login item: \(error.localizedDescription)"
        }
    }

    @objc private func saveClicked() {
        let hotkey = hotkeyField.stringValue.trimmingCharacters(in: .whitespaces)
        guard HotKey.parse(hotkey) != nil else {
            hotkeyNote.stringValue = "Not a valid hotkey; use modifiers + key, e.g. hyper+s."
            hotkeyNote.textColor = .systemRed
            return
        }
        func lines(_ area: (scroll: NSScrollView, text: NSTextView)) -> [String] {
            area.text.string.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var updated = base
        updated.hotkey = hotkey
        updated.roots = lines(roots).map(Scanner.canonical)
        updated.excludes = lines(excludes)
        updated.includes = lines(includes)
        updated.useDefaultExcludes = defaults.state == .on
        if updated.roots.isEmpty { updated.roots = base.roots }
        applyLogin()
        updated.openAtLogin = atLogin.state == .on
        onSave(updated)
        refreshLoginState()
        if SMAppService.mainApp.status == .requiresApproval { return }   // keep the note visible
        orderOut(nil)
    }

    @objc private func cancelClicked() { orderOut(nil) }

    private static func textArea() -> (scroll: NSScrollView, text: NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        return (scroll, text)
    }
}
