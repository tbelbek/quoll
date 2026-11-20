import Foundation
import AppKit
import Darwin
import QuollCore

private let stderr = FileHandle.standardError

private func fail(_ message: String) -> Never {
    stderr.write(Data("quoll: \(message)\n".utf8))
    exit(1)
}

private func printError(_ message: String) {
    stderr.write(Data("quoll: \(message)\n".utf8))
}

private func value(for option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

private func has(_ flag: String, in arguments: [String]) -> Bool {
    arguments.contains(flag)
}

private func positionals(_ arguments: [String], optionsWithValues: Set<String>) -> [String] {
    var result: [String] = []
    var index = 0
    var afterSeparator = false
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            afterSeparator = true
            index += 1
            continue
        }
        if !afterSeparator, argument.hasPrefix("-") {
            if optionsWithValues.contains(argument) {
                index += 2
            } else {
                index += 1
            }
            continue
        }
        result.append(argument)
        index += 1
    }
    return result
}

private func openSettings(dataDirectory: String?) -> Preferences {
    do {
        return try Preferences.load(dataDirectory: dataDirectory)
    } catch {
        fail("unable to load settings: \(error.localizedDescription)")
    }
}

private func client(for settings: Preferences) -> ControlClient? {
    let client = ControlClient(controlPath: settings.controlPath)
    return client.isAvailable() ? client : nil
}

private func dateString(_ date: Date) -> String {
    guard date != .distantPast else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func pad(_ value: String, _ width: Int) -> String {
    if value.count >= width {
        return String(value.prefix(width))
    }
    return value + String(repeating: " ", count: width - value.count)
}

private func printTable(_ response: QueryResult) {
    print("\(pad("NAME", 38)) \(pad("SIZE", 9)) \(pad("MODIFIED", 16)) PATH")
    for entry in response.results {
        print("\(pad(entry.name, 38)) \(pad(entry.isDirectory ? "<DIR>" : entry.formattedSize, 9)) \(pad(dateString(entry.modified), 16)) \(entry.path)")
    }
    let suffix = response.truncated ? " (showing \(response.count) of \(response.total))" : ""
    print("\n\(response.total) results in \(String(format: "%.1f", response.tookMS)) ms\(suffix)")
    for warning in response.warnings {
        printError("warning: \(warning)")
    }
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else {
        fail("unable to encode JSON")
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// MARK: - Commands

private func commandSearch(_ arguments: [String], settings: Preferences) {
    let queryParts = positionals(arguments, optionsWithValues: ["--limit", "--offset", "--sort"])
    var query = queryParts.joined(separator: " ")
    if has("--pattern", in: arguments) { query = "pattern:" + query }
    if has("--exact-case", in: arguments) { query = "matchcase:" + query }

    let limit = Int(value(for: "--limit", in: arguments) ?? "") ?? settings.defaultLimit
    let offset = Int(value(for: "--offset", in: arguments) ?? "") ?? 0
    let sort = SortKey(rawValue: value(for: "--sort", in: arguments) ?? "name") ?? .name
    let ascending = !has("--descending", in: arguments)

    let options = QueryOptions(
        query: query,
        limit: limit,
        offset: offset,
        sort: sort,
        ascending: ascending
    )

    if let client = client(for: settings) {
        do {
            let response = try client.send(ControlRequest(
                command: "search",
                query: options.query,
                limit: options.limit,
                offset: options.offset,
                sort: options.sort,
                ascending: options.ascending
            ))
            guard response.ok else {
                fail(response.error?.message ?? "search failed")
            }
            let search = QueryResult(
                query: options.query,
                count: response.count ?? 0,
                total: response.total ?? 0,
                tookMS: response.tookMS ?? 0,
                truncated: (response.total ?? 0) > (response.count ?? 0),
                results: response.results ?? []
            )
            var withWarnings = search
            withWarnings.warnings = response.warnings ?? []
            if has("--json", in: arguments) {
                printJSON(withWarnings)
            } else {
                printTable(withWarnings)
            }
            return
        } catch {
            printError("service unavailable, using archive: \(error.localizedDescription)")
        }
    }

    let catalog = Catalog()
    do {
        try catalog.load(from: settings.catalogURL)
    } catch {
        fail("no index at \(settings.catalogURL.path); run `quoll index <paths>` first")
    }
    let response = QueryEngine().search(options, in: catalog)
    if has("--json", in: arguments) {
        printJSON(response)
    } else {
        printTable(response)
    }
}

private func commandScan(_ arguments: [String], settings: Preferences) {
    let paths = positionals(arguments, optionsWithValues: ["--exclude"])
    let roots = paths.isEmpty ? settings.roots : paths.map(Scanner.standardize)
    let excludes = settings.excludes + [value(for: "--exclude", in: arguments)].compactMap { $0 }

    if let client = client(for: settings) {
        do {
            let request = paths.isEmpty
                ? ControlRequest(command: "rebuild")
                : ControlRequest(command: "scan", paths: roots)
            let response = try client.send(request)
            guard response.ok else { fail(response.error?.message ?? "index failed") }
            print(response.message ?? "scanned")
            return
        } catch {
            printError("service unavailable, indexing locally: \(error.localizedDescription)")
        }
    }

    let scanner = Scanner()
    let result = scanner.scan(
        roots: roots,
        options: Scanner.Options(
            excludes: excludes,
            skipHidden: settings.skipHidden,
            skipPackages: settings.skipPackages,
            followSymlinks: settings.followSymlinks
        ),
        progress: { count in
            if count % 20_000 == 0 {
                printError("scanned \(count) entries...")
            }
        }
    )

    let catalog = Catalog()
    catalog.replaceAll(with: result.entries, roots: roots)
    var updated = settings
    updated.roots = roots
    if !excludes.isEmpty { updated.excludes = excludes }
    do {
        try updated.save()
        try catalog.save(to: updated.catalogURL)
    } catch {
        fail("unable to save index: \(error.localizedDescription)")
    }

    print("scanned \(result.entries.count) entries in \(String(format: "%.1f", result.duration))s")
    if !result.errors.isEmpty {
        printError("\(result.errors.count) paths could not be read")
    }
}

private func commandStatus(_ arguments: [String], settings: Preferences) {
    if let client = client(for: settings) {
        do {
            let response = try client.send(ControlRequest(command: "status"))
            guard let status = response.status else { fail("no status") }
            if has("--json", in: arguments) {
                printJSON(status)
            } else {
                print("files:        \(status.files)")
                print("directories:  \(status.directories)")
                print("roots:        \(status.roots.joined(separator: ", "))")
                print("last scan: \(status.lastScan.map { dateString($0) } ?? "never")")
                print("archive:     \(ByteCountFormatter.string(fromByteCount: status.catalogBytes, countStyle: .file))")
                print("control:      \(status.controlPath)")
            }
            return
        } catch {
            printError("service unavailable: \(error.localizedDescription)")
        }
    }

    let catalog = Catalog()
    try? catalog.load(from: settings.catalogURL)
    let status = CatalogStatus(
        files: catalog.fileTotal,
        directories: catalog.folderTotal,
        roots: settings.roots,
        lastScan: catalog.lastScan,
        catalogBytes: (try? FileManager.default.attributesOfItem(atPath: settings.catalogURL.path)[.size] as? NSNumber)?.int64Value ?? 0,
        controlPath: settings.controlPath,
        uptime: 0
    )
    if has("--json", in: arguments) {
        printJSON(status)
    } else {
        print("files:        \(status.files)")
        print("directories:  \(status.directories)")
        print("roots:        \(status.roots.joined(separator: ", "))")
        print("last scan: \(status.lastScan.map { dateString($0) } ?? "never")")
        print("archive:     \(ByteCountFormatter.string(fromByteCount: status.catalogBytes, countStyle: .file))")
        print("control:      \(status.controlPath) (service not running)")
    }
}

private func commandOpen(_ arguments: [String], settings: Preferences, reveal: Bool) {
    guard let path = positionals(arguments, optionsWithValues: []).first else {
        fail("\(reveal ? "reveal" : "open") requires a path")
    }
    if let client = client(for: settings) {
        do {
            let response = try client.send(ControlRequest(command: reveal ? "reveal" : "open", path: path))
            guard response.ok else { fail(response.error?.message ?? "operation failed") }
            return
        } catch {
            printError("service unavailable: \(error.localizedDescription)")
        }
    }
    if reveal {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

private func commandExport(_ arguments: [String], settings: Preferences) {
    let format = ReportFormat(rawValue: value(for: "--format", in: arguments) ?? "json") ?? .json
    let query = positionals(arguments, optionsWithValues: ["--format", "--output"]).joined(separator: " ")

    let data: Data
    if let client = client(for: settings) {
        do {
            let response = try client.send(ControlRequest(command: "export", query: query, format: format.rawValue))
            guard response.ok, let text = response.data else {
                fail(response.error?.message ?? "export failed")
            }
            data = Data(text.utf8)
        } catch {
            printError("service unavailable, exporting from archive: \(error.localizedDescription)")
            data = exportLocally(query: query, format: format, settings: settings)
        }
    } else {
        data = exportLocally(query: query, format: format, settings: settings)
    }

    if let output = value(for: "--output", in: arguments) {
        do {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("wrote \(data.count) bytes to \(output)")
        } catch {
            fail("unable to write \(output): \(error.localizedDescription)")
        }
    } else {
        FileHandle.standardOutput.write(data)
    }
}

private func exportLocally(query: String, format: ReportFormat, settings: Preferences) -> Data {
    let catalog = Catalog()
    do {
        try catalog.load(from: settings.catalogURL)
    } catch {
        fail("no index at \(settings.catalogURL.path); run `quoll index <paths>` first")
    }
    let response = QueryEngine().search(
        QueryOptions(query: query, limit: 0, sort: .path, ascending: true),
        in: catalog
    )
    return ReportWriter.export(response.results, format: format)
}

private func commandServe(_ arguments: [String], settings: Preferences) {
    var updated = settings
    if has("--http", in: arguments) {
        updated.http.enabled = true
        if let port = Int(value(for: "--port", in: arguments) ?? "") {
            updated.http.port = port
        }
        if let username = value(for: "--username", in: arguments) {
            updated.http.username = username
        }
        if let password = value(for: "--password", in: arguments) {
            updated.http.password = password
        }
        if let root = value(for: "--root", in: arguments) {
            updated.http.root = root
        }
    }
    do {
        try updated.save()
    } catch {
        printError("unable to save settings: \(error.localizedDescription)")
    }

    let service = QuollService(settings: updated)
    do {
        try service.start(performInitialScan: !has("--no-scan", in: arguments))
    } catch {
        fail("unable to start service: \(error.localizedDescription)")
    }

    let signalQueue = DispatchQueue(label: "quoll.signals")
    var sources: [DispatchSourceSignal] = []
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
        source.setEventHandler {
            service.stop()
            exit(0)
        }
        source.resume()
        sources.append(source)
    }

    print("Quoll service running")
    print("control: \(updated.controlPath)")
    if updated.http.enabled {
        print("web:     http://127.0.0.1:\(updated.http.port)/search?q=")
    }
    fflush(stdout)

    dispatchMain()
}

private func commandSettings(_ arguments: [String], settings: Preferences) {
    var updated = settings
    var changed = false

    if has("--show", in: arguments) || arguments.isEmpty {
        printJSON(updated)
        return
    }
    if let root = value(for: "--add-root", in: arguments) {
        let normalized = Scanner.standardize(root)
        if !updated.roots.contains(normalized) {
            updated.roots.append(normalized)
            changed = true
        }
    }
    if let root = value(for: "--remove-root", in: arguments) {
        let normalized = Scanner.standardize(root)
        updated.roots.removeAll { $0 == normalized }
        changed = true
    }
    if let exclude = value(for: "--exclude", in: arguments) {
        if !updated.excludes.contains(exclude) {
            updated.excludes.append(exclude)
            changed = true
        }
    }
    if let exclude = value(for: "--remove-exclude", in: arguments) {
        updated.excludes.removeAll { $0 == exclude }
        changed = true
    }
    if has("--clear-excludes", in: arguments) {
        updated.excludes.removeAll()
        changed = true
    }

    if changed {
        do {
            try updated.save()
            printJSON(updated)
        } catch {
            fail("unable to save settings: \(error.localizedDescription)")
        }
    } else {
        printJSON(updated)
    }
}

private func usage() {
    print("""
    quoll — macOS filename search

    USAGE
      quoll find <query> [--limit N] [--offset N] [--sort name|path|size|modified|created|extension|level]
                          [--descending] [--json] [--pattern] [--exact-case]
      quoll scan [paths...] [--exclude PATTERN]
      quoll rebuild
      quoll status [--json]
      quoll serve [--http] [--port N] [--username U] [--password P] [--no-scan]
      quoll open <path>
      quoll reveal <path>
      quoll export [query] [--format json|csv|tsv] [--output FILE]
      quoll settings [--show] [--add-root PATH] [--remove-root PATH]
                     [--exclude PATTERN] [--remove-exclude PATTERN] [--clear-excludes]
      quoll help

    GLOBAL
      --data-dir PATH   override the application-support directory

    QUERY SYNTAX
      foo bar           AND
      foo|bar           OR
      !foo, -foo        NOT
      "foo bar"         phrase
      ending:swift      file extension
      kind:file         files only            kind:folder   folders only
      bytes:>1mb        size comparison
      changed:today     modification date
      made:2024-01..2024-06
      starts:Report     name starts with
      ends:.pdf         name ends with
      under:src         inside a folder
      path:src          path contains
      pattern:^v[0-9]+  regular expression
      level:>2          path depth
      blank:            empty files
    """)
}

// MARK: - Entry point

var arguments = Array(CommandLine.arguments.dropFirst())
var dataDirectory: String?
if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
    dataDirectory = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
}

guard let command = arguments.first else {
    usage()
    exit(0)
}
let rest = Array(arguments.dropFirst())

switch command {
case "search", "find":
    commandSearch(rest, settings: openSettings(dataDirectory: dataDirectory))
case "scan", "add":
    commandScan(rest, settings: openSettings(dataDirectory: dataDirectory))
case "rebuild":
    commandScan(rest, settings: openSettings(dataDirectory: dataDirectory))
case "status", "info":
    commandStatus(rest, settings: openSettings(dataDirectory: dataDirectory))
case "serve":
    commandServe(rest, settings: openSettings(dataDirectory: dataDirectory))
case "open":
    commandOpen(rest, settings: openSettings(dataDirectory: dataDirectory), reveal: false)
case "reveal":
    commandOpen(rest, settings: openSettings(dataDirectory: dataDirectory), reveal: true)
case "export":
    commandExport(rest, settings: openSettings(dataDirectory: dataDirectory))
case "settings":
    commandSettings(rest, settings: openSettings(dataDirectory: dataDirectory))
case "help", "--help", "-h":
    usage()
default:
    fail("unknown command '\(command)' (try `quoll help`)")
}
