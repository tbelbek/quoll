import AppKit
import QuollCore

/// Menu-bar app with an Everything-style search panel and a global hotkey.
/// AppKit only: no SwiftUI scene machinery in a process that idles in the background.
@main
enum QuollMain {
    static func main() {
        ScanHelper.runIfRequested()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no ⌘Tab entry
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var settings = Preferences.default()
    private var service: QuollService?
    private var backend: SearchBackend?
    private var panel: SearchPanel?
    private var controller: SearchController?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let countItem = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    private let showItem = NSMenuItem(title: "Show Quoll", action: #selector(togglePanel), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        setUpStatusItem()
        do {
            settings = try Preferences.load()
        } catch {
            countItem.title = "settings error: \(error.localizedDescription)"
        }
        backend = makeBackend()
        if let backend {
            let controller = SearchController(backend: backend)
            controller.onHide = { [weak self] in self?.hidePanel() }
            let panel = SearchPanel()
            panel.contentViewController = controller
            panel.delegate = self
            panel.keyHandler = { [weak controller] event in controller?.handleKeyEquivalent(event) ?? false }
            panel.setFrameAutosaveName("QuollSearch")
            if !panel.setFrameUsingName("QuollSearch") {
                panel.setContentSize(NSSize(width: 900, height: 520))
                panel.center()
            }
            self.controller = controller
            self.panel = panel
        }
        registerHotKey()
        // QUOLL_SHOW=<query>: open the panel at launch (screenshots, manual testing).
        if let query = ProcessInfo.processInfo.environment["QUOLL_SHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.togglePanel()
                self?.controller?.setQuery(query)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        service?.stop()
    }

    /// Use a running `quoll serve` if there is one; otherwise host the service here
    /// (one process, one TCC subject).
    private func makeBackend() -> SearchBackend? {
        let client = ControlClient(controlPath: settings.controlPath)
        if client.isAvailable() { return SocketBackend(client: client) }
        let service = QuollService(settings: settings)
        do {
            try service.start()
        } catch {
            countItem.title = "service error: \(error.localizedDescription)"
            return nil
        }
        self.service = service
        return InProcessBackend(service: service)
    }

    private func registerHotKey() {
        hotKey = HotKey(spec: settings.hotkey) { [weak self] in self?.togglePanel() }
        if let hotKey {
            showItem.title = "Show Quoll    \(hotKey.display)"
        } else {
            showItem.title = "Show Quoll    (hotkey “\(settings.hotkey)” unavailable)"
        }
    }

    // MARK: Panel

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible && panel.isKeyWindow {
            hidePanel()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            controller?.willShow()
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        controller?.didHide()
        NSApp.hide(nil)   // give focus back to the previous app
    }

    /// Like Everything/Spotlight: clicking elsewhere dismisses the window.
    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    // MARK: Menus

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Quoll")
        let menu = NSMenu()
        menu.delegate = self
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
        countItem.isEnabled = false
        menu.addItem(countItem)
        menu.addItem(withTitle: "Reindex", action: #selector(reindex), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open settings.json", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quoll", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let status = backend?.status() else { return }
        let total = status.files + status.directories
        countItem.title = total > 0 ? "\(total.formatted()) entries indexed" : "indexing…"
    }

    @objc private func reindex() { controller?.reindex() }

    @objc private func openSettings() {
        try? settings.save()
        NSWorkspace.shared.open(URL(fileURLWithPath: (settings.dataDirectory as NSString).appendingPathComponent("settings.json")))
    }

    /// Accessory apps show no menu bar, but the field editor still needs the Edit
    /// key equivalents (⌘A ⌘C ⌘V ⌘X ⌘Z).
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Quoll", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
