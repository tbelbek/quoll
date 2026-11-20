import Foundation

/// Pages search results for a virtualised table: only the visible rows exist as
/// `FileEntry` values (at most `maxPages * pageSize` at once). Used on the main
/// thread; `fetch` may answer asynchronously.
public final class ResultPager {
    public let pageSize: Int
    /// Rows a table offers; deeper offsets cost more in the engine and nobody
    /// scrolls past them — they refine the query.
    public let cap: Int
    public let maxPages: Int

    public private(set) var generation = 0
    public private(set) var total = 0
    public private(set) var tookMS = 0.0
    public private(set) var warnings: [String] = []
    public private(set) var query = ""
    public private(set) var sort: SortKey = .modified
    public private(set) var ascending = false

    public var rowCount: Int { min(total, cap) }
    public var isCapped: Bool { total > cap }
    public var cachedPages: Int { pages.count }

    /// `interactive`: a newer interactive fetch may cancel this one.
    /// `isCurrent`: false once a newer search started (skip stale queued work).
    public typealias Fetch = (_ options: QueryOptions, _ interactive: Bool,
                              _ isCurrent: @escaping () -> Bool,
                              _ reply: @escaping (QueryResult?) -> Void) -> Void

    /// A new result set is in (page 0 arrived).
    public var onReset: (() -> Void)?
    /// Rows of a later page arrived.
    public var onRows: ((Range<Int>) -> Void)?

    private let fetch: Fetch
    private var pages: [Int: [FileEntry]] = [:]
    private var recency: [Int] = []
    private var pending = Set<Int>()
    private let current = NSLock()
    private var currentGeneration = 0

    public init(pageSize: Int = 200, cap: Int = 10_000, maxPages: Int = 3, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.cap = cap
        self.maxPages = maxPages
        self.fetch = fetch
    }

    public func search(_ query: String, sort: SortKey, ascending: Bool) {
        self.query = query
        self.sort = sort
        self.ascending = ascending
        bump()
        request(page: 0, interactive: true)
    }

    /// Entry for a row, or nil while its page is being fetched.
    public func entry(at row: Int) -> FileEntry? {
        guard row >= 0, row < rowCount else { return nil }
        let page = row / pageSize
        if let rows = pages[page] {
            touch(page)
            let index = row - page * pageSize
            return index < rows.count ? rows[index] : nil
        }
        request(page: page, interactive: false)
        return nil
    }

    /// Frees every cached entry (window hidden); the next search refills it.
    public func dropCache() {
        bump()
    }

    private func bump() {
        generation += 1
        current.lock(); currentGeneration = generation; current.unlock()
        pages = [:]
        recency = []
        pending = []
    }

    private func request(page: Int, interactive: Bool) {
        guard !pending.contains(page) else { return }
        pending.insert(page)
        let generation = self.generation
        let options = QueryOptions(query: query, limit: pageSize, offset: page * pageSize,
                                   sort: sort, ascending: ascending)
        let isCurrent: () -> Bool = { [current = self.current, weak self] in
            guard let self else { return false }
            current.lock(); defer { current.unlock() }
            return self.currentGeneration == generation
        }
        fetch(options, interactive, isCurrent) { [weak self] result in
            self?.receive(page: page, generation: generation, result: result)
        }
    }

    private func receive(page: Int, generation: Int, result: QueryResult?) {
        guard generation == self.generation else { return }   // stale reply
        pending.remove(page)
        guard let result, !result.warnings.contains("cancelled") else { return }
        if page == 0 {
            total = result.total
            tookMS = result.tookMS
            warnings = result.warnings
        }
        pages[page] = result.results
        touch(page)
        while pages.count > maxPages, let oldest = recency.first {
            recency.removeFirst()
            pages[oldest] = nil
        }
        if page == 0 {
            onReset?()
        } else {
            let start = page * pageSize
            onRows?(start..<min(rowCount, start + result.results.count))
        }
    }

    private func touch(_ page: Int) {
        if let i = recency.firstIndex(of: page) { recency.remove(at: i) }
        recency.append(page)
    }
}
