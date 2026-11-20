import Foundation

/// Full scans run in a short-lived child process (the service's own executable
/// with `--quoll-scan-helper <request.json>`). The scan's buffers churn ~30 MB of
/// malloc pages that the allocator keeps after freeing (measured: footprint stays
/// at 34.6 MB after a 1.1M-entry scan, `malloc_zone_pressure_relief` frees
/// nothing); a process exit returns them all. D11 in docs/DECISIONS.md.
public enum ScanHelper {
    public static let flag = "--quoll-scan-helper"

    struct Request: Codable {
        var roots: [String]
        var settings: Preferences
        var directory: String
        var meta: SnapshotMeta
    }

    struct Reply: Codable {
        var entries: Int
        var folders: Int
        var unreadable: Int
        var duration: TimeInterval
        var error: String?
    }

    /// Call first thing in every executable that can host `QuollService`.
    public static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return }
        var reply = Reply(entries: 0, folders: 0, unreadable: 0, duration: 0, error: nil)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])))
            let stats = try IndexStore.scan(roots: request.roots, rules: request.settings.excludeRules,
                                            into: request.directory, meta: request.meta)
            reply = Reply(entries: stats.entries, folders: stats.folders, unreadable: stats.unreadable,
                          duration: stats.duration, error: nil)
        } catch {
            reply.error = "\(error)"
        }
        FileHandle.standardOutput.write((try? JSONEncoder().encode(reply)) ?? Data())
        exit(reply.error == nil ? 0 : 1)
    }

    /// Scans in a child process; falls back to scanning in-process if the child
    /// cannot be started.
    static func scan(roots: [String], settings: Preferences, into directory: String,
                     meta: SnapshotMeta) throws -> BulkScanner.Stats {
        guard let executable = Bundle.main.executableURL else {
            return try IndexStore.scan(roots: roots, rules: settings.excludeRules, into: directory, meta: meta)
        }
        let requestURL = URL(fileURLWithPath: directory + ".request.json")
        defer { try? FileManager.default.removeItem(at: requestURL) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Request(roots: roots, settings: settings, directory: directory, meta: meta)).write(to: requestURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = [flag, requestURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return try IndexStore.scan(roots: roots, rules: settings.excludeRules, into: directory, meta: meta)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw StoreError.io("scan helper exited with status \(process.terminationStatus)")
        }
        if let error = reply.error { throw StoreError.io("scan helper: \(error)") }
        var stats = BulkScanner.Stats()
        stats.entries = reply.entries
        stats.folders = reply.folders
        stats.unreadable = reply.unreadable
        stats.duration = reply.duration
        return stats
    }
}
