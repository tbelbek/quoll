import SwiftUI
import Combine
import AppKit
import QuollCore

@main
struct QuollApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Quoll", systemImage: "magnifyingglass") {
            SearchView(model: model)
                .frame(width: 720, height: 460)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [FileEntry] = []
    @Published var total: Int = 0
    @Published var tookMS: Double = 0
    @Published var statusText: String = "starting…"
    @Published var selected: FileEntry?
    @Published var warnings: [String] = []

    private(set) var settings: Preferences?
    private var service: QuollService?
    private var client: ControlClient?
    private var searchWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "quoll.app", qos: .userInitiated)

    init() {
        start()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let settings = try Preferences.load()
                DispatchQueue.main.async {
                    self.settings = settings
                    self.statusText = "connecting…"
                }

                let client = ControlClient(controlPath: settings.controlPath)
                if client.isAvailable() {
                    DispatchQueue.main.async {
                        self.client = client
                        self.statusText = "connected to service"
                    }
                    self.refreshStatus()
                    self.performSearch()
                    return
                }

                let service = QuollService(settings: settings)
                try service.start()
                DispatchQueue.main.async {
                    self.service = service
                    self.client = nil
                    self.statusText = "indexing…"
                }
                self.refreshStatus()
                self.performSearch()
            } catch {
                DispatchQueue.main.async {
                    self.statusText = "error: \(error.localizedDescription)"
                }
            }
        }
    }

    func scheduleSearch() {
        searchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performSearch()
        }
        searchWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func performSearch() {
        let query = self.query
        if let client {
            do {
                let response = try client.send(ControlRequest(
                    command: "search",
                    query: query,
                    limit: 500,
                    sort: .name,
                    ascending: true
                ))
                DispatchQueue.main.async {
                    self.results = response.results ?? []
                    self.total = response.total ?? 0
                    self.tookMS = response.tookMS ?? 0
                    self.warnings = response.warnings ?? []
                    self.statusText = "\(self.total) results"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusText = "service error: \(error.localizedDescription)"
                }
            }
            return
        }

        guard let service else { return }
        let response = service.engine.search(
            QueryOptions(query: query, limit: 500, sort: .name, ascending: true),
            in: service.catalog
        )
        DispatchQueue.main.async {
            self.results = response.results
            self.total = response.total
            self.tookMS = response.tookMS
            self.warnings = response.warnings
            self.statusText = "\(self.total) results"
        }
    }

    func refreshStatus() {
        if let client {
            if let response = try? client.send(ControlRequest(command: "status")),
               let status = response.status {
                DispatchQueue.main.async {
                    self.statusText = "\(status.files) files · \(status.directories) folders"
                }
            }
            return
        }
        guard let service else { return }
        let status = service.status()
        DispatchQueue.main.async {
            self.statusText = "\(status.files) files · \(status.directories) folders"
        }
    }

    func open(_ entry: FileEntry) {
        if let client {
            _ = try? client.send(ControlRequest(command: "open", path: entry.path))
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    func reveal(_ entry: FileEntry) {
        if let client {
            _ = try? client.send(ControlRequest(command: "reveal", path: entry.path))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
    }

    func copyPath(_ entry: FileEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
    }

    func rebuild() {
        statusText = "reindexing…"
        queue.async { [weak self] in
            guard let self else { return }
            if let client = self.client {
                _ = try? client.send(ControlRequest(command: "rebuild"))
            } else if let service = self.service {
                _ = service.rebuild()
            }
            self.refreshStatus()
            self.performSearch()
        }
    }

    func quit() {
        service?.stop()
        NSApp.terminate(nil)
    }
}

struct SearchView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files and folders", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onChange(of: model.query) { _ in
                        model.scheduleSearch()
                    }
                    .onSubmit {
                        model.performSearch()
                    }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.performSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.bar)

            Divider()

            if model.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Type to search the index" : "No results")
                        .foregroundStyle(.secondary)
                    if !model.warnings.isEmpty {
                        Text(model.warnings.joined(separator: "\n"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.results, selection: $model.selected) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder" : iconName(for: entry.fileExtension))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .lineLimit(1)
                            Text((entry.path as NSString).deletingLastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !entry.isDirectory {
                            Text(entry.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        model.open(entry)
                    }
                    .contextMenu {
                        Button("Open") { model.open(entry) }
                        Button("Reveal in Finder") { model.reveal(entry) }
                        Divider()
                        Button("Copy Path") { model.copyPath(entry) }
                    }
                    .tag(entry)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 10) {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.tookMS > 0 {
                    Text("· \(String(format: "%.1f", model.tookMS)) ms")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Reindex") { model.rebuild() }
                    .controlSize(.small)
                Button("Quit") { model.quit() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .onAppear { searchFocused = true }
    }

    private func iconName(for fileExtension: String) -> String {
        switch fileExtension {
        case "swift", "c", "h", "cpp", "hpp", "m", "mm": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "mp3", "wav", "m4a", "flac": return "music.note"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "zip", "gz", "tar", "7z", "rar": return "archivebox"
        case "pdf": return "doc.richtext"
        case "app": return "app"
        default: return "doc"
        }
    }
}
