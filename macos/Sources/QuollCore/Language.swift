import Foundation

// MARK: - SearchQuery model

public indirect enum Expr: Sendable, Equatable {
    case all
    case and([Expr])
    case or([Expr])
    case not(Expr)
    case term(Predicate)
}

public enum MatchMode: String, Sendable, Equatable {
    case substring
    case exact
    case prefix
    case suffix
    case wildcard
    case regex
    case wordsOnly
}

public enum NumberRule: Sendable, Equatable {
    case less(Int64)
    case lessOrEqual(Int64)
    case greater(Int64)
    case greaterOrEqual(Int64)
    case equal(Int64)
    case range(Int64, Int64)

    public func matches(_ value: Int64) -> Bool {
        switch self {
        case .less(let v): return value < v
        case .lessOrEqual(let v): return value <= v
        case .greater(let v): return value > v
        case .greaterOrEqual(let v): return value >= v
        case .equal(let v): return value == v
        case .range(let low, let high): return value >= low && value <= high
        }
    }
}

public enum DateRule: Sendable, Equatable {
    case before(Date)
    case after(Date)
    case onDay(Date)
    case range(Date, Date)

    public func matches(_ value: Date) -> Bool {
        switch self {
        case .before(let date): return value < date
        case .after(let date): return value > date
        case .onDay(let date):
            let calendar = Calendar.current
            return calendar.isDate(value, inSameDayAs: date)
        case .range(let start, let end):
            return value >= start && value <= end
        }
    }
}

public struct Predicate: Sendable, Equatable {
    public var text: String = ""
    public var matchMode: MatchMode = .substring
    public var caseSensitive: Bool = false
    public var useFullPath: Bool = false
    public var filesOnly: Bool?
    public var fileExtension: String?
    public var pathFragment: String?
    public var under: String?
    public var parentPath: String?
    public var bytes: NumberRule?
    public var changed: DateRule?
    public var made: DateRule?
    public var touched: DateRule?
    public var chars: NumberRule?
    public var level: NumberRule?
    public var blank: Bool?

    public init() {}

    public var isUnconstrained: Bool {
        text.isEmpty
            && filesOnly == nil
            && fileExtension == nil
            && pathFragment == nil
            && under == nil
            && parentPath == nil
            && bytes == nil
            && changed == nil
            && made == nil
            && touched == nil
            && chars == nil
            && level == nil
            && blank == nil
    }
}

public struct SearchQuery: Sendable {
    public var raw: String
    public var root: Expr
    public var warnings: [String]

    public init(raw: String, root: Expr, warnings: [String]) {
        self.raw = raw
        self.root = root
        self.warnings = warnings
    }
}

// MARK: - Parser

public enum SearchParser {
    enum Token: Equatable {
        case word(String)
        case or
        case not
        case lparen
        case rparen
    }

    private struct Parser {
        var tokens: [Token]
        var index: Int = 0
        var warnings: [String] = []

        // Defaults changed by standalone modifiers such as `matchcase:` and `leafonly:`.
        var caseSensitive = false
        var patternMode = false
        var useFullPath = false
        var wordsOnly = false

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func parse() -> Expr {
            if tokens.isEmpty { return .all }
            var root = parseOr()
            if index < tokens.count {
                warnings.append("unexpected token at position \(index)")
                while index < tokens.count { _ = parseNot() }
                root = .and([root, parseOr()])
            }
            return root
        }

        mutating func parseOr() -> Expr {
            var nodes: [Expr] = [parseAnd()]
            while match(.or) {
                nodes.append(parseAnd())
            }
            return nodes.count == 1 ? nodes[0] : .or(nodes)
        }

        mutating func parseAnd() -> Expr {
            var nodes: [Expr] = []
            while let token = peek() {
                if token == .or || token == .rparen { break }
                nodes.append(parseNot())
            }
            if nodes.isEmpty { return .all }
            return nodes.count == 1 ? nodes[0] : .and(nodes)
        }

        mutating func parseNot() -> Expr {
            if match(.not) {
                return .not(parseNot())
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Expr {
            if match(.lparen) {
                let root = parseOr()
                _ = match(.rparen)
                return root
            }
            guard let token = next() else { return .all }
            switch token {
            case .word(let value):
                return parseWord(value)
            case .or, .not, .lparen, .rparen:
                warnings.append("unexpected operator")
                return .all
            }
        }

        mutating func parseWord(_ raw: String) -> Expr {
            var working = raw
            var appliedFilter = false
            var hasExplicitTextMode = false
            var term = Predicate()

            // Leading modifiers, e.g. `leafonly:leaf:foo` or `pattern:^v[0-9]+`.
            while let (prefix, value) = Self.splitPrefix(working), let modifier = Modifier(rawValue: prefix) {
                if !apply(modifier: modifier) {
                    // Prefix with an inline value such as `matchcase:foo` sets the default
                    // and continues parsing the rest as the term.
                    _ = value
                }
                working = value
                if working.isEmpty {
                    return .all
                }
            }

            // Text-mode prefixes consume the rest of the token themselves.
            if let (prefix, value) = Self.splitPrefix(working), let textFilter = TextFilter(rawValue: prefix) {
                term.text = value
                term.matchMode = textFilter.mode
                if textFilter.forcesName { term.useFullPath = false }
                hasExplicitTextMode = true
                working = ""
            } else if let (prefix, value) = Self.splitPrefix(working), let filter = Filter(rawValue: prefix) {
                appliedFilter = true
                apply(filter: filter, value: value, to: &term)
                working = ""
            }

            if !appliedFilter, let colon = working.firstIndex(of: ":"), colon != working.startIndex {
                let candidate = String(working[working.startIndex..<colon]).lowercased()
                if candidate.range(of: "^[a-z][a-z0-9]*$", options: .regularExpression) != nil {
                    warnings.append("unsupported filter '\(candidate):'")
                }
            }

            if !working.isEmpty {
                term.text = working
                if !hasExplicitTextMode {
                    term.matchMode = matchMode(for: working)
                }
            }
            term.caseSensitive = caseSensitive
            term.useFullPath = term.useFullPath || useFullPath
            if wordsOnly && term.matchMode == .substring {
                term.matchMode = .wordsOnly
            }
            if patternMode && term.matchMode == .substring {
                term.matchMode = .regex
            }
            if term.isUnconstrained { return .all }
            return .term(term)
        }

        func matchMode(for text: String) -> MatchMode {
            if patternMode { return .regex }
            if text.contains("*") || text.contains("?") { return .wildcard }
            if wordsOnly { return .wordsOnly }
            return .substring
        }

        @discardableResult
        mutating func apply(modifier: Modifier) -> Bool {
            switch modifier {
            case .caseSensitive: caseSensitive = true
            case .caseInsensitive: caseSensitive = false
            case .regex: patternMode = true
            case .noRegex: patternMode = false
            case .useFullPath: useFullPath = true
            case .noPath: useFullPath = false
            case .wordsOnly: wordsOnly = true
            case .noWholeWord: wordsOnly = false
            }
            return true
        }

        mutating func apply(filter: Filter, value: String, to term: inout Predicate) {
            switch filter {
            case .kind:
                switch value.lowercased() {
                case "file", "files": term.filesOnly = true
                case "folder", "folders", "dir", "directory": term.filesOnly = false
                default: warnings.append("kind expects file or folder")
                }
            case .blank:
                term.blank = true
            case .ending:
                // One or more extensions: `ending:pdf`, `ending:jpg;png;heic` (`,` works too).
                term.fileExtension = Self.extensionList(value).joined(separator: ";")
            case .path:
                term.pathFragment = value
            case .under:
                // `/abs` or `~/x` is a folder path; a bare value is a folder name.
                term.under = Self.isAbsolute(value) ? Self.standardize(value) : value
            case .parent:
                term.parentPath = Self.isAbsolute(value) ? Self.standardize(value) : value
            case .bytes:
                term.bytes = Self.parseNumeric(value)
            case .changed:
                term.changed = Self.parseDate(value)
            case .made:
                term.made = Self.parseDate(value)
            case .touched:
                term.touched = Self.parseDate(value)
            case .chars:
                term.chars = Self.parseNumeric(value)
            case .level:
                term.level = Self.parseNumeric(value)
            }
        }

        // MARK: token helpers

        mutating func peek() -> Token? {
            index < tokens.count ? tokens[index] : nil
        }

        mutating func next() -> Token? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        mutating func match(_ token: Token) -> Bool {
            guard peek() == token else { return false }
            index += 1
            return true
        }

        // MARK: value parsing

        static func splitPrefix(_ value: String) -> (String, String)? {
            guard let colon = value.firstIndex(of: ":") else { return nil }
            let prefix = String(value[value.startIndex..<colon]).lowercased()
            guard !prefix.isEmpty,
                  prefix.range(of: "^[a-z][a-z0-9]*$", options: .regularExpression) != nil else {
                return nil
            }
            return (prefix, String(value[value.index(after: colon)...]))
        }

        static func standardize(_ path: String) -> String {
            Scanner.standardize(path)
        }

        static func extensionList(_ value: String) -> [String] {
            value.lowercased().split(whereSeparator: { $0 == ";" || $0 == "," }).map { part in
                var ending = String(part).trimmingCharacters(in: .whitespaces)
                if ending.hasPrefix("*.") { ending = String(ending.dropFirst(2)) }
                if ending.hasPrefix(".") { ending = String(ending.dropFirst()) }
                return ending
            }
        }

        static func isAbsolute(_ value: String) -> Bool {
            value.hasPrefix("/") || value.hasPrefix("~")
        }

        static func parseNumeric(_ raw: String) -> NumberRule? {
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if value.contains("..") {
                let parts = value.components(separatedBy: "..")
                guard parts.count == 2,
                      let low = parseSize(parts[0]),
                      let high = parseSize(parts[1]) else { return nil }
                return .range(low, high)
            }
            let prefixes: [(String, (Int64) -> NumberRule)] = [
                (">=", NumberRule.greaterOrEqual),
                ("<=", NumberRule.lessOrEqual),
                (">", NumberRule.greater),
                ("<", NumberRule.less),
                ("=", NumberRule.equal)
            ]
            for (prefix, builder) in prefixes where value.hasPrefix(prefix) {
                guard let number = parseSize(String(value.dropFirst(prefix.count))) else { return nil }
                return builder(number)
            }
            guard let number = parseSize(value) else { return nil }
            return .equal(number)
        }

        static func parseSize(_ raw: String) -> Int64? {
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !value.isEmpty else { return nil }
            let suffixes: [(String, Double)] = [
                ("tib", 1024 * 1024 * 1024 * 1024),
                ("tb", 1024 * 1024 * 1024 * 1024),
                ("gib", 1024 * 1024 * 1024),
                ("gb", 1024 * 1024 * 1024),
                ("mib", 1024 * 1024),
                ("mb", 1024 * 1024),
                ("kib", 1024),
                ("kb", 1024),
                ("t", 1024 * 1024 * 1024 * 1024),
                ("g", 1024 * 1024 * 1024),
                ("m", 1024 * 1024),
                ("k", 1024),
                ("b", 1)
            ]
            for (suffix, multiplier) in suffixes where value.hasSuffix(suffix) {
                let number = String(value.dropLast(suffix.count))
                guard let parsed = Double(number) else { return nil }
                return Int64(parsed * multiplier)
            }
            if let parsed = Double(value) { return Int64(parsed) }
            return nil
        }

        /// Dates name a period: a day, a month (`2025-06`) or a year (`2025`).
        /// A bare value matches the whole period; comparisons use its bounds, so
        /// `>2025` means after 2025 and `<=2025-06` means up to the end of June.
        /// Times are whole seconds, so [start, end) is `start ... end - 1 s`.
        static func parseDate(_ raw: String) -> DateRule? {
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if value.contains("..") {
                let parts = value.components(separatedBy: "..")
                guard parts.count == 2, let low = period(parts[0]), let high = period(parts[1]) else { return nil }
                return .range(low.start, high.end.addingTimeInterval(-1))
            }
            for op in [">=", "<=", ">", "<", "="] where value.hasPrefix(op) {
                guard let p = period(String(value.dropFirst(op.count))) else { return nil }
                switch op {
                case ">=": return .after(p.start.addingTimeInterval(-1))
                case "<=": return .before(p.end)
                case ">": return .after(p.end.addingTimeInterval(-1))
                case "<": return .before(p.start)
                default: return .range(p.start, p.end.addingTimeInterval(-1))
                }
            }
            guard let p = period(value) else { return nil }
            return .range(p.start, p.end.addingTimeInterval(-1))
        }

        /// `today`, `yesterday`, `YYYY`, `YYYY-MM`, `YYYY-MM-DD` → [start, end).
        static func period(_ raw: String) -> (start: Date, end: Date)? {
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let calendar = Calendar.current
            func day(_ date: Date) -> (Date, Date) {
                let start = calendar.startOfDay(for: date)
                return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start)
            }
            if value == "today" { return day(Date()) }
            if value == "yesterday" { return day(calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()) }
            let parts = value.split(separator: "-").map { Int($0) }
            guard !parts.isEmpty, !parts.contains(nil), let year = parts[0], value.count >= 4 else { return nil }
            var components = DateComponents(year: year, month: 1, day: 1)
            let unit: Calendar.Component
            switch parts.count {
            case 1: unit = .year
            case 2: components.month = parts[1]; unit = .month
            case 3: components.month = parts[1]; components.day = parts[2]; unit = .day
            default: return nil
            }
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
            return (start, end)
        }
    }

    private enum Modifier: String {
        case caseSensitive = "matchcase"
        case caseInsensitive = "icase"
        case regex = "pattern"
        case noRegex = "plain"
        case useFullPath = "fullpath"
        case noPath = "leafonly"
        case wordsOnly = "word"
        case noWholeWord = "anyword"
    }

    private enum Filter: String {
        case kind
        case ending
        case path
        case under
        case parent
        case bytes
        case changed
        case made
        case touched
        case chars
        case level
        case blank
    }

    private enum TextFilter: String {
        case starts
        case ends
        case exact
        case leaf

        var mode: MatchMode {
            switch self {
            case .starts: return .prefix
            case .ends: return .suffix
            case .exact: return .exact
            case .leaf: return .substring
            }
        }

        var forcesName: Bool {
            switch self {
            case .leaf: return true
            default: return false
            }
        }
    }

    public static func parse(_ input: String) -> SearchQuery {
        var lexer = Lexer(input)
        let tokens = lexer.tokenize()
        var parser = Parser(tokens: tokens)
        let root = parser.parse()
        var warnings = parser.warnings
        warnings.append(contentsOf: lexer.warnings.map { $0 })
        return SearchQuery(raw: input, root: root, warnings: warnings)
    }
}

// MARK: - Lexer

private struct Lexer {
    let input: String
    var warnings: [String] = []

    init(_ input: String) { self.input = input }

    mutating func tokenize() -> [SearchParser.Token] {
        var tokens: [SearchParser.Token] = []
        var current = ""
        var inQuotes = false
        var index = input.startIndex

        func flush() {
            if !current.isEmpty {
                tokens.append(.word(current))
                current = ""
            }
        }

        while index < input.endIndex {
            let character = input[index]

            if inQuotes {
                if character == "\\", input.index(after: index) < input.endIndex,
                   input[input.index(after: index)] == "\"" {
                    current.append("\"")
                    index = input.index(index, offsetBy: 2)
                    continue
                }
                if character == "\"" {
                    inQuotes = false
                    index = input.index(after: index)
                    continue
                }
                current.append(character)
                index = input.index(after: index)
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
                index = input.index(after: index)
            case "(":
                flush()
                tokens.append(.lparen)
                index = input.index(after: index)
            case ")":
                flush()
                tokens.append(.rparen)
                index = input.index(after: index)
            case "|":
                flush()
                tokens.append(.or)
                index = input.index(after: index)
            case " ", "\t", "\n":
                flush()
                index = input.index(after: index)
            case "!", "-":
                if current.isEmpty {
                    flush()
                    tokens.append(.not)
                    index = input.index(after: index)
                } else {
                    current.append(character)
                    index = input.index(after: index)
                }
            default:
                current.append(character)
                index = input.index(after: index)
            }
        }

        if inQuotes {
            warnings.append("unterminated quote")
        }
        flush()
        return tokens
    }
}

// MARK: - Predicate matching

public final class Matcher {
    private let query: SearchQuery
    private var regexCache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    public init(query: SearchQuery) {
        self.query = query
    }

    public func matches(_ entry: FileEntry) -> Bool {
        matches(query.root, entry)
    }

    private func matches(_ root: Expr, _ entry: FileEntry) -> Bool {
        switch root {
        case .all:
            return true
        case .and(let nodes):
            return nodes.allSatisfy { matches($0, entry) }
        case .or(let nodes):
            return nodes.contains { matches($0, entry) }
        case .not(let root):
            return !matches(root, entry)
        case .term(let term):
            return matches(term, entry)
        }
    }

    private func matches(_ term: Predicate, _ entry: FileEntry) -> Bool {
        switch term.filesOnly {
        case .some(true) where entry.isDirectory: return false
        case .some(false) where !entry.isDirectory: return false
        default: break
        }

        if let ext = term.fileExtension, !ext.split(separator: ";").contains(Substring(entry.fileExtension)) { return false }

        if let pathFragment = term.pathFragment {
            let options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
            if entry.path.range(of: pathFragment, options: options) == nil { return false }
        }

        if let prefix = term.under {
            if prefix.hasPrefix("/") {
                if !(entry.path == prefix || entry.path.hasPrefix(prefix + "/")) { return false }
            } else {
                // Folder name anywhere above the entry (or the entry itself, if a folder).
                let key = Fold.fold(prefix)
                var components = entry.path.split(separator: "/").map(String.init)
                if !entry.isDirectory { components.removeLast() }
                if !components.contains(where: { Fold.fold($0) == key }) { return false }
            }
        }

        if let parent = term.parentPath {
            let actual = (entry.path as NSString).deletingLastPathComponent
            if parent.hasPrefix("/") {
                if actual != parent { return false }
            } else if Fold.fold((actual as NSString).lastPathComponent) != Fold.fold(parent) {
                return false
            }
        }

        if let size = term.bytes, !size.matches(entry.size) { return false }
        if let modified = term.changed, !modified.matches(entry.modified) { return false }
        if let created = term.made, !created.matches(entry.created) { return false }
        if let accessed = term.touched, !accessed.matches(entry.accessed) { return false }
        if let length = term.chars, !length.matches(Int64(entry.name.count)) { return false }
        if let depth = term.level, !depth.matches(Int64(entry.level)) { return false }
        if let empty = term.blank {
            if empty {
                if entry.isDirectory { return false }
                if entry.size != 0 { return false }
            } else if !entry.isDirectory || entry.size == 0 {
                return false
            }
        }

        if !term.text.isEmpty, !matchesText(term, entry) { return false }
        return true
    }

    private func matchesText(_ term: Predicate, _ entry: FileEntry) -> Bool {
        let haystack = term.useFullPath ? entry.path : entry.name
        let options: String.CompareOptions = term.caseSensitive
            ? []
            : [.caseInsensitive, .diacriticInsensitive]

        switch term.matchMode {
        case .substring:
            return haystack.range(of: term.text, options: options) != nil
        case .exact:
            return haystack.compare(term.text, options: options) == .orderedSame
        case .prefix:
            return haystack.range(of: term.text, options: options.union(.anchored)) != nil
        case .suffix:
            return haystack.range(of: term.text, options: options.union([.anchored, .backwards])) != nil
        case .wildcard:
            let pattern = "^" + Self.escapeRegex(term.text)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
            return regex(pattern, caseSensitive: term.caseSensitive).firstMatch(
                in: haystack,
                range: NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
            ) != nil
        case .regex:
            return regex(term.text, caseSensitive: term.caseSensitive).firstMatch(
                in: haystack,
                range: NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
            ) != nil
        case .wordsOnly:
            let pattern = "(?<![\\p{L}\\p{N}_])" + Self.escapeRegex(term.text) + "(?![\\p{L}\\p{N}_])"
            return regex(pattern, caseSensitive: term.caseSensitive).firstMatch(
                in: haystack,
                range: NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
            ) != nil
        }
    }

    private func regex(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression {
        let key = (caseSensitive ? "1" : "0") + pattern
        lock.lock()
        if let cached = regexCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let compiled = (try? NSRegularExpression(pattern: pattern, options: options))
            ?? (try! NSRegularExpression(pattern: Self.escapeRegex(pattern), options: options))
        lock.lock()
        regexCache[key] = compiled
        lock.unlock()
        return compiled
    }

    static func escapeRegex(_ value: String) -> String {
        let specials = CharacterSet(charactersIn: "\\^$|()[]{}.+*?")
        var output = ""
        for scalar in value.unicodeScalars {
            if specials.contains(scalar) {
                output.append("\\")
            }
            output.append(Character(scalar))
        }
        return output
    }
}
