import Foundation

public enum ReportFormat: String, Sendable {
    case json
    case csv
    case tsv
}

public enum ReportWriter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func export(_ entries: [FileEntry], format: ReportFormat) -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            return (try? encoder.encode(entries)) ?? Data("[]".utf8)
        case .csv:
            return Data(table(entries, separator: ",").utf8)
        case .tsv:
            return Data(table(entries, separator: "\t").utf8)
        }
    }

    private static func table(_ entries: [FileEntry], separator: String) -> String {
        var lines = [["Name", "Path", "Bytes", "Changed", "Created", "Kind"].joined(separator: separator)]
        for entry in entries {
            lines.append([
                escape(entry.name, separator: separator),
                escape(entry.path, separator: separator),
                String(entry.size),
                escape(dateFormatter.string(from: entry.modified), separator: separator),
                escape(dateFormatter.string(from: entry.created), separator: separator),
                entry.isDirectory ? "folder" : "file"
            ].joined(separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ value: String, separator: String) -> String {
        let needsQuotes = value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
