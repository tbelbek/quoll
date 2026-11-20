import Foundation
import AppKit

public final class QuollService {
    public var settings: Preferences
    public let catalog: Catalog
    public let engine = QueryEngine()

    private let scanner = Scanner()
    private let startedAt = Date()
    private let stateQueue = DispatchQueue(label: "quoll.service.state")
    private let lock = NSLock()
    private var control: ControlServer?
    private var monitor: ChangeWatcher?
    private var http: WebServer?
    private var saveWorkItem: DispatchWorkItem?
    private var running = false

    public init(settings: Preferences) {
        self.settings = settings
        self.catalog = Catalog()
    }

    // MARK: - Lifecycle

    public func start(performInitialScan: Bool = true) throws {
        guard !running else { return }
        try settings.ensureDirectories()

        if FileManager.default.fileExists(atPath: settings.catalogURL.path) {
            do {
                try catalog.load(from: settings.catalogURL)
            } catch {
                log("unable to load archive: \(error.localizedDescription)")
            }
        }

        if performInitialScan && catalog.count == 0 {
            let result = rebuild()
            log("initial scan: \(result.entries.count) entries in \(String(format: "%.1f", result.duration))s")
        }

        let server = ControlServer(controlPath: settings.controlPath) { [weak self] request in
            guard let self else {
                return ControlReply.failure("unavailable", "service is not running", id: request.id)
            }
            return self.handle(request)
        }
        try server.start()
        control = server

        let monitor = ChangeWatcher(paths: settings.roots) { [weak self] paths in
            self?.applyChanges(paths)
        }
        do {
            try monitor.start()
            self.monitor = monitor
        } catch {
            log("unable to start FSEvents monitor: \(error.localizedDescription)")
        }

        if settings.http.enabled {
            startHTTP()
        }

        running = true
        log("listening on \(settings.controlPath)")
    }

    public func stop() {
        guard running else { return }
        running = false
        monitor?.stop()
        monitor = nil
        http?.stop()
        http = nil
        control?.stop()
        control = nil
        try? catalog.save(to: settings.catalogURL)
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Indexing

    @discardableResult
    public func rebuild() -> ScanResult {
        stateQueue.sync {
            let result = scanner.scan(
                roots: settings.roots,
                options: scanOptions
            )
            catalog.replaceAll(with: result.entries, roots: settings.roots)
            persist()
            return result
        }
    }

    @discardableResult
    public func scan(paths: [String], replaceRoots: Bool = true) -> ScanResult {
        stateQueue.sync {
            let normalized = paths.map(Scanner.standardize)
            if replaceRoots, !normalized.isEmpty {
                settings.roots = normalized
                try? settings.save()
            }
            let roots = normalized.isEmpty ? settings.roots : normalized
            let result = scanner.scan(roots: roots, options: scanOptions)
            if replaceRoots {
                catalog.replaceAll(with: result.entries, roots: roots)
            } else {
                catalog.insert(contentsOf: result.entries)
                catalog.markScanned()
            }
            persist()
            return result
        }
    }

    private func applyChanges(_ paths: [String]) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            for path in paths {
                let normalized = Scanner.standardize(path)

                guard FileManager.default.fileExists(atPath: normalized) else {
                    self.catalog.removeBranch(path: normalized)
                    continue
                }

                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: normalized,
                    isDirectory: &isDirectory
                )

                if isDirectory.boolValue {
                    let result = self.scanner.scan(
                        roots: [normalized],
                        options: self.scanOptions
                    )
                    var entries = result.entries
                    if let rootRecord = try? FileEntry(url: URL(fileURLWithPath: normalized)) {
                        if !Scanner.isExcluded(rootRecord, excludes: self.settings.excludes) {
                            entries.append(rootRecord)
                        }
                    }
                    self.catalog.removeBranch(path: normalized)
                    self.catalog.insert(contentsOf: entries)
                } else if let entry = try? FileEntry(url: URL(fileURLWithPath: normalized)) {
                    if !Scanner.isExcluded(entry, excludes: self.settings.excludes) {
                        self.catalog.put(entry)
                    }
                }
            }
            self.catalog.markScanned()
            self.scheduleSave()
        }
    }

    private var scanOptions: Scanner.Options {
        Scanner.Options(
            excludes: settings.excludes,
            skipHidden: settings.skipHidden,
            skipPackages: settings.skipPackages,
            followSymlinks: settings.followSymlinks
        )
    }

    private func persist() {
        do {
            try catalog.save(to: settings.catalogURL)
        } catch {
            log("unable to save archive: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persist()
        }
        saveWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - Status

    public func status() -> CatalogStatus {
        let attributes = try? FileManager.default.attributesOfItem(atPath: settings.catalogURL.path)
        let catalogBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return CatalogStatus(
            files: catalog.fileTotal,
            directories: catalog.folderTotal,
            roots: settings.roots,
            lastScan: catalog.lastScan,
            catalogBytes: catalogBytes,
            controlPath: settings.controlPath,
            uptime: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: - IPC commands

    public func handle(_ request: ControlRequest) -> ControlReply {
        switch request.command {
        case "ping":
            return ControlReply(id: request.id, message: "pong")

        case "search":
            let options = QueryOptions(
                query: request.query ?? "",
                limit: request.limit ?? settings.defaultLimit,
                offset: request.offset ?? 0,
                sort: request.sort ?? .name,
                ascending: request.ascending ?? true
            )
            let response = engine.search(options, in: catalog)
            return ControlReply(
                id: request.id,
                count: response.count,
                total: response.total,
                tookMS: response.tookMS,
                results: response.results,
                warnings: response.warnings
            )

        case "status":
            return ControlReply(id: request.id, status: status())

        case "scan":
            let paths = request.paths ?? []
            let result = scan(paths: paths, replaceRoots: !paths.isEmpty)
            return ControlReply(
                id: request.id,
                message: "scanned \(result.entries.count) entries in \(String(format: "%.1f", result.duration))s"
            )

        case "rebuild":
            let result = rebuild()
            return ControlReply(
                id: request.id,
                message: "rescanned \(result.entries.count) entries in \(String(format: "%.1f", result.duration))s"
            )

        case "forget":
            guard let path = request.path else {
                return .failure("bad_request", "forget requires path", id: request.id)
            }
            catalog.removeBranch(path: Scanner.standardize(path))
            scheduleSave()
            return ControlReply(id: request.id, message: "forgotten")

        case "open":
            guard let path = request.path else {
                return .failure("bad_request", "open requires path", id: request.id)
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return ControlReply(id: request.id, message: "opened")

        case "reveal":
            guard let path = request.path else {
                return .failure("bad_request", "reveal requires path", id: request.id)
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return ControlReply(id: request.id, message: "revealed")

        case "export":
            let format = ReportFormat(rawValue: request.format ?? "json") ?? .json
            let options = QueryOptions(
                query: request.query ?? "",
                limit: 0,
                sort: request.sort ?? .path,
                ascending: true
            )
            let response = engine.search(options, in: catalog)
            let data = ReportWriter.export(response.results, format: format)
            return ControlReply(
                id: request.id,
                count: response.results.count,
                data: String(data: data, encoding: .utf8) ?? ""
            )

        case "stop":
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.stop()
            }
            return ControlReply(id: request.id, message: "shutting down")

        default:
            return .failure("unknown_command", "unknown command '\(request.command)'", id: request.id)
        }
    }

    // MARK: - HTTP

    private func startHTTP() {
        let server = WebServer(
            port: settings.http.port,
            username: settings.http.username,
            password: settings.http.password
        ) { [weak self] request in
            guard let self else {
                return WebReply.text("service stopped", status: 500)
            }
            return self.handleHTTP(request)
        }
        do {
            try server.start()
            http = server
            log("HTTP listening on port \(settings.http.port)")
        } catch {
            log("unable to start HTTP server: \(error.localizedDescription)")
        }
    }

    private func handleHTTP(_ request: WebRequest) -> WebReply {
        switch request.path {
        case "/search":
            let query = (request.query["q"] ?? "").replacingOccurrences(of: "+", with: " ")
            let limit = Int(request.query["limit"] ?? "") ?? settings.defaultLimit
            let sort = SortKey(rawValue: request.query["sort"] ?? "") ?? .name
            let ascending = (request.query["asc"] ?? "1") != "0"
            let options = QueryOptions(
                query: query,
                limit: limit,
                sort: sort,
                ascending: ascending
            )
            let response = engine.search(options, in: catalog)

            if request.query["json"] == "1" || (request.headers["accept"] ?? "").contains("application/json") {
                return .json(response)
            }
            return .text(Self.html(results: response, query: query), contentType: "text/html; charset=utf-8")

        case "/status":
            return .json(status())

        case "/export":
            let format = ReportFormat(rawValue: request.query["format"] ?? "json") ?? .json
            let options = QueryOptions(
                query: (request.query["q"] ?? "").replacingOccurrences(of: "+", with: " "),
                limit: 0,
                sort: .path,
                ascending: true
            )
            let response = engine.search(options, in: catalog)
            let data = ReportWriter.export(response.results, format: format)
            let contentType: String
            switch format {
            case .json: contentType = "application/json"
            case .csv: contentType = "text/csv"
            case .tsv: contentType = "text/tab-separated-values"
            }
            return WebReply(
                status: 200,
                headers: ["Content-Type": "\(contentType); charset=utf-8"],
                body: data
            )

        default:
            return serveStatic(request.path)
        }
    }

    private func serveStatic(_ path: String) -> WebReply {
        let root = settings.http.root
            ?? (settings.dataDirectory as NSString).appendingPathComponent("http")
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.contains("..") else {
            return .text("not found", status: 404)
        }
        var file = (root as NSString).appendingPathComponent(decoded)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), isDirectory.boolValue {
            file = (file as NSString).appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            return .text("not found", status: 404)
        }
        let ext = (file as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "html", "htm": contentType = "text/html; charset=utf-8"
        case "css": contentType = "text/css"
        case "js": contentType = "application/javascript"
        case "json": contentType = "application/json"
        case "png": contentType = "image/png"
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "svg": contentType = "image/svg+xml"
        default: contentType = "application/octet-stream"
        }
        return WebReply(headers: ["Content-Type": contentType], body: data)
    }

    private static func html(results: QueryResult, query: String) -> String {
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        let rows = results.results.map { entry in
            "<tr><td><a href=\"file://\(escape(entry.path))\">\(escape(entry.name))</a></td><td class=\"path\">\(escape((entry.path as NSString).deletingLastPathComponent))</td><td class=\"num\">\(entry.isDirectory ? "" : escape(entry.formattedSize))</td></tr>"
        }.joined()

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <title>Quoll</title>
        <style>
        body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;margin:24px;color:#111}
        input[type=search]{width:min(720px,100%);padding:10px 12px;font-size:16px;border:1px solid #ccc;border-radius:8px}
        table{border-collapse:collapse;width:100%;margin-top:16px}
        td,th{text-align:left;padding:6px 8px;border-bottom:1px solid #eee}
        .path{color:#777}.num{text-align:right;white-space:nowrap}
        form{margin-bottom:8px}
        </style></head><body>
        <form action="/search" method="get">
        <input type="search" name="q" value="\(escape(query))" placeholder="Search files..." autofocus>
        </form>
        <div>\(results.total) results in \(String(format: "%.1f", results.tookMS)) ms</div>
        <table><thead><tr><th>Name</th><th>Path</th><th>Size</th></tr></thead><tbody>\(rows)</tbody></table>
        </body></html>
        """
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[quoll] \(message)\n".utf8))
    }
}
