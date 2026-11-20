import Foundation

public final class QueryEngine {
    public init() {}

    public func search(_ options: QueryOptions, in catalog: Catalog) -> QueryResult {
        let started = Date()
        let query = SearchParser.parse(options.query)
        let evaluator = Matcher(query: query)

        var matched = catalog.allEntries().filter { entry in
            if !options.includeFiles && !entry.isDirectory { return false }
            if !options.includeDirectories && entry.isDirectory { return false }
            return evaluator.matches(entry)
        }

        let total = matched.count

        matched.sort { lhs, rhs in
            compare(lhs, rhs, by: options.sort, ascending: options.ascending)
        }

        let offset = max(0, options.offset)
        let limit = options.limit <= 0 ? matched.count : options.limit
        let start = min(offset, matched.count)
        let end = min(start + limit, matched.count)
        let page = start < end ? Array(matched[start..<end]) : []

        let took = Date().timeIntervalSince(started) * 1000
        var response = QueryResult(
            query: options.query,
            count: page.count,
            total: total,
            tookMS: took,
            truncated: end < matched.count,
            results: page
        )
        response.warnings = query.warnings
        return response
    }

    private func compare(_ lhs: FileEntry, _ rhs: FileEntry, by key: SortKey, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .path:
            result = lhs.path.localizedStandardCompare(rhs.path)
        case .fileExtension:
            result = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
        case .size:
            result = compareValues(lhs.size, rhs.size)
        case .modified:
            result = compareValues(lhs.modified.timeIntervalSince1970, rhs.modified.timeIntervalSince1970)
        case .created:
            result = compareValues(lhs.created.timeIntervalSince1970, rhs.created.timeIntervalSince1970)
        case .accessed:
            result = compareValues(lhs.accessed.timeIntervalSince1970, rhs.accessed.timeIntervalSince1970)
        case .level:
            result = compareValues(lhs.level, rhs.level)
        }

        if result == .orderedSame {
            return lhs.path < rhs.path
        }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
