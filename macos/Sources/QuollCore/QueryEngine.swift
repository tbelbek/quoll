import Foundation

/// Evaluates parsed queries against an `IndexStore`.
///
/// - A single plain substring term runs `memmem` over whole chunks of the base
///   name arena (no per-entry work for non-matching names).
/// - Anything else is evaluated per entry, cheap column predicates first and
///   path / regex / access-time predicates last.
/// - Chunks run on all cores; each keeps a bounded top-K heap, so nothing sorts
///   more than the requested page.
public final class QueryEngine {
    private let generationLock = NSLock()
    private var generation = 0

    public init() {}

    /// `cancellable`: a newer cancellable search abandons this one (interactive typing).
    public func search(_ options: QueryOptions, in store: IndexStore, cancellable: Bool = false) -> QueryResult {
        let started = Date()
        let parsed = SearchParser.parse(options.query)
        var token = -1
        if cancellable {
            generationLock.lock()
            generation += 1
            token = generation
            generationLock.unlock()
        }
        let isStale: () -> Bool = { [weak self] in
            guard token >= 0, let self else { return false }
            self.generationLock.lock()
            defer { self.generationLock.unlock() }
            return self.generation != token
        }

        var result = store.read { () -> QueryResult in
            let plan = Plan(query: parsed, options: options, store: store)
            let (total, ids, cancelled) = plan.run(isStale: isStale)
            let page = ids.map { plan.entry($0) }
            var result = QueryResult(query: options.query, count: page.count, total: total, tookMS: 0,
                                     truncated: total > options.offset + page.count, results: page)
            if cancelled { result.warnings.append("cancelled") }
            return result
        }
        result.warnings.append(contentsOf: parsed.warnings)
        result.tookMS = Date().timeIntervalSince(started) * 1000
        return result
    }
}

// MARK: - Plan

private final class Plan {
    let store: IndexStore
    let options: QueryOptions
    /// Folded full path of each root (roots store their full path as raw name).
    let rootFolded: [[UInt8]]

    // Flattened, reference-free query tree: evaluating it never touches ARC,
    // which dominated the per-entry cost (profiled: >90% retain/release).
    struct FlatNode {
        enum Kind: UInt8 { case all, none, and, or, not, term }
        var kind: Kind
        var first: Int32 = 0   // children: childIndex[first ..< first + count]; term: term index
        var count: Int32 = 0
    }
    private var nodes: [FlatNode] = []
    private var childIndex: [Int32] = []
    private let nodePtr: UnsafeMutableBufferPointer<FlatNode>
    private let childPtr: UnsafeMutableBufferPointer<Int32>
    let terms: UnsafeMutableBufferPointer<Term>
    private var termList: [Term] = []
    private let rootIndex: Int
    /// Literal every match must contain in its folded name (memmem driver), and
    /// whether the literal alone decides the match.
    private let driver: UnsafeMutableBufferPointer<UInt8>?
    private let driverDecides: Bool

    init(query: SearchQuery, options: QueryOptions, store: IndexStore) {
        self.store = store
        self.options = options
        rootFolded = (0..<store.rootCount).map { Fold.fold(store.meta.roots[$0]) }
        var nodes: [FlatNode] = []
        var children: [Int32] = []
        var termList: [Term] = []

        func add(_ expr: Expr) -> Int {
            switch expr {
            case .all:
                nodes.append(FlatNode(kind: .all)); return nodes.count - 1
            case .not(let inner):
                let child = add(inner)
                let first = Int32(children.count); children.append(Int32(child))
                nodes.append(FlatNode(kind: .not, first: first, count: 1)); return nodes.count - 1
            case .term(let predicate):
                termList.append(Term(predicate, store: store))
                nodes.append(FlatNode(kind: .term, first: Int32(termList.count - 1))); return nodes.count - 1
            case .and(let list), .or(let list):
                var kids = list.map { add($0) }
                if case .and = expr {
                    // Cheapest first, so expensive predicates see few candidates.
                    kids.sort { Self.cost(nodes[$0], termList) < Self.cost(nodes[$1], termList) }
                }
                let first = Int32(children.count)
                children.append(contentsOf: kids.map(Int32.init))
                let isAnd: Bool = { if case .and = expr { return true }; return false }()
                nodes.append(FlatNode(kind: isAnd ? .and : .or, first: first, count: Int32(kids.count)))
                return nodes.count - 1
            }
        }
        rootIndex = add(query.root)
        self.nodes = nodes
        childIndex = children
        self.termList = termList
        nodePtr = .allocate(capacity: max(1, nodes.count))
        _ = nodePtr.initialize(from: nodes)
        childPtr = .allocate(capacity: max(1, children.count))
        _ = childPtr.initialize(from: children)
        terms = .allocate(capacity: max(1, termList.count))
        _ = terms.initialize(from: termList)

        // Driver: the longest required literal of the root term or of a direct AND child.
        var best: [UInt8] = []
        var decides = false
        let root = nodes[rootIndex]
        var candidates: [Int] = []
        if root.kind == .term { candidates = [Int(root.first)] }
        if root.kind == .and {
            for k in children[Int(root.first)..<Int(root.first + root.count)] where nodes[Int(k)].kind == .term {
                candidates.append(Int(nodes[Int(k)].first))
            }
        }
        for t in candidates {
            let literal = termList[t].requiredLiteral
            if literal.count > best.count {
                best = literal
                decides = root.kind == .term && termList[t].isPlainSubstring
            }
        }
        if best.isEmpty || best.contains(0) {
            driver = nil
        } else {
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: best.count)
            _ = buffer.initialize(from: best)
            driver = buffer
        }
        driverDecides = decides && driver != nil
    }

    deinit {
        for t in terms { t.release() }
        nodePtr.deallocate()
        childPtr.deallocate()
        terms.deallocate()
        driver?.deallocate()
    }

    private static func cost(_ node: FlatNode, _ terms: [Term]) -> Int {
        node.kind == .term ? terms[Int(node.first)].cost : 1
    }

    // MARK: Running

    func run(isStale: () -> Bool) -> (total: Int, ids: [Int], cancelled: Bool) {
        let k = options.limit <= 0 ? Int.max : options.offset + options.limit
        let order = Order(key: options.sort, ascending: options.ascending, plan: self)
        let count = store.count
        let first = store.rootCount
        guard count > first else { return (0, [], false) }

        let chunkSize = 32_768
        let chunks = (count - first + chunkSize - 1) / chunkSize
        let partials = UnsafeMutableBufferPointer<Partial>.allocate(capacity: chunks)
        partials.initialize(repeating: Partial())
        defer { partials.deallocate() }
        var cancelled = false
        let cancelLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            if isStale() {
                cancelLock.lock(); cancelled = true; cancelLock.unlock()
                return
            }
            let lo = first + c * chunkSize
            let hi = min(count, lo + chunkSize)
            var heap = TopK(limit: order.collectsAll ? Int.max : k, before: order.before)
            var total = 0
            var ctx = EvalContext()
            if let driver {
                scanArena(lo: lo, hi: hi, literal: UnsafeBufferPointer(driver), ctx: &ctx) { id in
                    total += 1
                    heap.insert(id)
                }
            } else if rootIsAll && !order.collectsAll && k != Int.max {
                // Empty query: gate on the raw sort key so most entries never reach
                // the comparator closure (ties still go through it).
                let ascending = options.ascending
                let key = options.sort
                for id in lo..<hi where accepts(id) {
                    total += 1
                    if heap.items.count >= k {
                        let worst = heap.items[0]
                        let c: Int
                        switch key {
                        case .modified: c = Self.cmp(store.mtime(id), store.mtime(worst))
                        case .size: c = Self.cmp(store.size(id), store.size(worst))
                        case .created: c = Self.cmp(store.meta(id).ctime, store.meta(worst).ctime)
                        default: c = IndexStore.compare(store.folded(id), store.folded(worst))
                        }
                        if ascending ? c > 0 : c < 0 { continue }
                    }
                    heap.insert(id)
                }
            } else {
                for id in lo..<hi where accepts(id) && eval(rootIndex, id, &ctx) {
                    total += 1
                    heap.insert(id)
                }
            }
            partials[c] = Partial(total: total, ids: heap.items)
        }
        if cancelled { return (0, [], true) }

        var total = 0
        var merged = TopK(limit: order.collectsAll ? Int.max : k, before: order.before)
        for partial in partials {
            total += partial.total
            for id in partial.ids { merged.insert(id) }
        }
        let sorted = order.finalize(merged.items)
        let start = min(options.offset, sorted.count)
        let end = options.limit <= 0 ? sorted.count : min(sorted.count, start + options.limit)
        return (total, Array(sorted[start..<end]), false)
    }

    private var rootIsAll: Bool { nodePtr[rootIndex].kind == .all }

    @inline(__always) static func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }

    struct Partial {
        var total = 0
        var ids: [Int] = []
    }

    @inline(__always) func accepts(_ id: Int) -> Bool {
        if store.isDead(id) { return false }
        let dir = store.isDirectory(id)
        if dir && !options.includeDirectories { return false }
        if !dir && !options.includeFiles { return false }
        return true
    }

    /// memmem of the driver literal over the base arena chunk; only hits are
    /// evaluated. Delta and renamed entries are evaluated per entry.
    private func scanArena(lo: Int, hi: Int, literal: UnsafeBufferPointer<UInt8>, ctx: inout EvalContext,
                           _ hit: (Int) -> Void) {
        let base = store.baseCount
        if lo < base {
            let (bytes, offsets, _) = store.baseArena
            let end = min(hi, base)
            var position = Int(offsets[lo])
            let limit = Int(offsets[end])
            let needle = UnsafeRawPointer(literal.baseAddress!)
            while position < limit {
                guard let found = memmem(bytes + position, limit - position, needle, literal.count) else { break }
                let offset = UnsafeRawPointer(found) - UnsafeRawPointer(bytes)
                // id = last entry whose start offset <= offset
                var a = lo, b = end
                while a < b {
                    let mid = (a + b) >> 1
                    if Int(offsets[mid]) <= offset { a = mid + 1 } else { b = mid }
                }
                let id = a - 1
                if accepts(id) && !store.hasNameOverride(id) && (driverDecides || eval(rootIndex, id, &ctx)) { hit(id) }
                position = Int(offsets[id + 1])
            }
            // Renamed base entries carry their new name outside the arena.
            for id in lo..<end where store.hasNameOverride(id) && accepts(id) && eval(rootIndex, id, &ctx) { hit(id) }
        }
        if hi > base {
            for id in max(lo, base)..<hi where accepts(id) && eval(rootIndex, id, &ctx) { hit(id) }
        }
    }

    // MARK: Evaluation

    private func eval(_ index: Int, _ id: Int, _ ctx: inout EvalContext) -> Bool {
        let node = nodePtr[index]
        switch node.kind {
        case .all: return true
        case .none: return false
        case .term: return terms[Int(node.first)].matches(id, plan: self, ctx: &ctx)
        case .not: return !eval(Int(childPtr[Int(node.first)]), id, &ctx)
        case .and:
            for k in Int(node.first)..<Int(node.first + node.count) where !eval(Int(childPtr[k]), id, &ctx) { return false }
            return true
        case .or:
            for k in Int(node.first)..<Int(node.first + node.count) where eval(Int(childPtr[k]), id, &ctx) { return true }
            return false
        }
    }

    // MARK: Path helpers

    /// Full path bytes, folded or raw.
    func pathBytes(_ id: Int, folded: Bool, into out: inout [UInt8]) {
        out.removeAll(keepingCapacity: true)
        var chain: [Int] = []
        var cursor = id
        while cursor >= 0 {
            chain.append(cursor)
            cursor = store.parent(cursor)
        }
        for (n, node) in chain.reversed().enumerated() {
            if n == 0 {
                if folded, node < rootFolded.count { out.append(contentsOf: rootFolded[node]) }
                else { out.append(contentsOf: store.raw(node)) }
                continue
            }
            if out.last != UInt8(ascii: "/") { out.append(UInt8(ascii: "/")) }
            out.append(contentsOf: folded ? store.folded(node) : store.raw(node))
        }
    }

    func entry(_ id: Int) -> FileEntry {
        let path = store.path(id)
        let name = String(decoding: store.raw(id), as: UTF8.self)
        let meta = store.meta(id)
        var st = stat()
        let accessed = lstat(path, &st) == 0
            ? Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
            : Date(timeIntervalSince1970: TimeInterval(meta.mtime))
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let mount = components.count > 1 && components[0] == "Volumes" ? "/Volumes/\(components[1])" : "/"
        return FileEntry(path: path, name: name, isDirectory: store.isDirectory(id), size: Int64(meta.size),
                         modified: Date(timeIntervalSince1970: TimeInterval(meta.mtime)),
                         created: Date(timeIntervalSince1970: TimeInterval(meta.ctime)),
                         accessed: accessed, fileExtension: (name as NSString).pathExtension.lowercased(),
                         level: store.depth(id), mount: mount)
    }

    func accessTime(_ id: Int) -> Date {
        var st = stat()
        guard lstat(store.path(id), &st) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
    }
}

// MARK: - Evaluation context

/// Per-chunk scratch for path predicates. Children of a folder sit next to each
/// other in id order, so the parent's path is built once per run of siblings
/// instead of once per entry (`path:` without a name literal went 275 ms → see D14).
private struct EvalContext {
    var parent = Int.min
    var parentFolded: [UInt8] = []
    var parentRaw: [UInt8] = []
    var haveFolded = false
    var haveRaw = false
    var scratch: [UInt8] = []
    /// "Parent path contains needle", remembered for the current parent per needle.
    var containsParent = Int.min
    var containsNeedle: UnsafePointer<UInt8>?
    var containsFolded = false
    var containsResult = false

    mutating func parentPath(of id: Int, folded: Bool, plan: Plan) -> [UInt8] {
        let p = plan.store.parent(id)
        if p != parent {
            parent = p
            haveFolded = false
            haveRaw = false
        }
        if folded {
            if !haveFolded { plan.pathBytes(p, folded: true, into: &parentFolded); haveFolded = true }
            return parentFolded
        }
        if !haveRaw { plan.pathBytes(p, folded: false, into: &parentRaw); haveRaw = true }
        return parentRaw
    }

    /// Full path of `id` (parent from the cache) into `scratch`.
    mutating func fullPath(of id: Int, folded: Bool, plan: Plan) {
        let base = parentPath(of: id, folded: folded, plan: plan)
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: base)
        if scratch.last != UInt8(ascii: "/") { scratch.append(UInt8(ascii: "/")) }
        scratch.append(contentsOf: folded ? plan.store.folded(id) : plan.store.raw(id))
    }

    /// Does the full path of `id` contain `needle`? Only the parent path and the
    /// window across the last separator are examined.
    mutating func pathContains(_ id: Int, _ needle: UnsafeBufferPointer<UInt8>, folded: Bool, plan: Plan) -> Bool {
        let base = parentPath(of: id, folded: folded, plan: plan)
        if containsParent != parent || containsNeedle != needle.baseAddress || containsFolded != folded {
            containsParent = parent
            containsNeedle = needle.baseAddress
            containsFolded = folded
            containsResult = base.withUnsafeBufferPointer { Term.contains($0, needle) }
        }
        if containsResult { return true }
        // Not in the parent path: the match must lie in the name, or (if the needle
        // has a "/") end in the name with the needle's last segment as its prefix.
        let name = folded ? plan.store.folded(id) : plan.store.raw(id)
        guard let slash = needle.lastIndex(of: UInt8(ascii: "/")) else { return Term.contains(name, needle) }
        let tail = UnsafeBufferPointer(rebasing: needle[(slash + 1)...])
        guard name.count >= tail.count,
              IndexStore.compare(UnsafeBufferPointer(rebasing: name[0..<tail.count]), tail) == 0 else { return false }
        scratch.removeAll(keepingCapacity: true)
        let keep = min(base.count, max(0, needle.count - 1))
        scratch.append(contentsOf: base[(base.count - keep)...])
        if base.last != UInt8(ascii: "/") { scratch.append(UInt8(ascii: "/")) }
        scratch.append(contentsOf: folded ? plan.store.folded(id) : plan.store.raw(id))
        return scratch.withUnsafeBufferPointer { Term.contains($0, needle) }
    }
}

// MARK: - Term

/// Seconds interval with optional strict bounds (DateRule without Foundation types).
private struct SecondsRule {
    var lo = -Double.infinity, hi = Double.infinity
    var loStrict = false, hiStrict = false

    init(_ rule: DateRule) {
        switch rule {
        case .before(let d): hi = d.timeIntervalSince1970; hiStrict = true
        case .after(let d): lo = d.timeIntervalSince1970; loStrict = true
        case .range(let a, let b): lo = a.timeIntervalSince1970; hi = b.timeIntervalSince1970
        case .onDay(let d):
            let start = Calendar.current.startOfDay(for: d)
            lo = start.timeIntervalSince1970
            hi = (Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start).timeIntervalSince1970
            hiStrict = true
        }
    }

    @inline(__always) func matches(_ seconds: Double) -> Bool {
        (loStrict ? seconds > lo : seconds >= lo) && (hiStrict ? seconds < hi : seconds <= hi)
    }
}

/// Bytes owned by a plan (freed with it); a plain pointer keeps `Term` POD.
private struct Bytes {
    var base: UnsafeMutablePointer<UInt8>?
    var count = 0

    init() {}
    init(_ array: [UInt8]) {
        count = array.count
        base = .allocate(capacity: max(1, array.count))
        base!.initialize(from: array, count: array.count)
    }

    var buffer: UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(start: base, count: count) }
    var array: [UInt8] { Array(buffer) }
    func free() { base?.deallocate() }
}

private struct Term {
    var hasFilesOnly = false, filesOnly = false
    /// Folded extensions, NUL-separated (`ending:jpg;png` → "jpg\0png"); one raw
    /// buffer keeps `Term` free of reference-counted fields (D7).
    var ext: Bytes?
    var bytes: NumberRule?
    var changed: SecondsRule?
    var made: SecondsRule?
    var touched: SecondsRule?
    var chars: NumberRule?
    var level: NumberRule?
    var hasBlank = false, blank = false
    var under: Unmanaged<Membership>?
    var parents: Unmanaged<Membership>?
    var pathFragment: Bytes?
    var pathCaseSensitive = false
    var needle = Bytes()
    var mode: MatchMode = .substring
    var caseSensitive = false
    var fullPath = false
    var regex: Unmanaged<NSRegularExpression>?
    var hasText = false
    var literal = Bytes()

    var isPlainSubstring: Bool {
        hasText && mode == .substring && !caseSensitive && !fullPath
            && !hasFilesOnly && ext == nil && bytes == nil && changed == nil && made == nil
            && touched == nil && chars == nil && level == nil && !hasBlank && under == nil
            && parents == nil && pathFragment == nil && needle.count > 0
    }

    /// Bytes every matching entry's folded name must contain.
    var requiredLiteral: [UInt8] { literal.array }

    /// Rough evaluation cost, used to order AND children.
    var cost: Int {
        if touched != nil || regex != nil || pathFragment != nil || fullPath { return 3 }
        if chars != nil || level != nil { return 2 }
        if hasText || under != nil || parents != nil { return 1 }
        return 0
    }

    init(_ p: Predicate, store: IndexStore) {
        if let f = p.filesOnly { hasFilesOnly = true; filesOnly = f }
        var extLiteral: [UInt8] = []
        if let e = p.fileExtension {
            let list = e.split(separator: ";", omittingEmptySubsequences: false).map { Fold.fold(String($0)) }
            ext = Bytes(Array(list.joined(separator: [0])))
            // A single extension is a literal the name must contain (".md").
            if list.count == 1, !list[0].isEmpty { extLiteral = [UInt8(ascii: ".")] + list[0] }
        }
        bytes = p.bytes
        changed = p.changed.map(SecondsRule.init)
        made = p.made.map(SecondsRule.init)
        touched = p.touched.map(SecondsRule.init)
        chars = p.chars
        level = p.level
        if let b = p.blank { hasBlank = true; blank = b }
        if let u = p.under { under = Unmanaged.passRetained(Membership(target: u, store: store, includeTargets: true)) }
        if let parent = p.parentPath {
            parents = Unmanaged.passRetained(Membership(target: parent, store: store, includeTargets: false))
        }
        if let fragment = p.pathFragment {
            pathCaseSensitive = p.caseSensitive
            pathFragment = Bytes(p.caseSensitive ? Array(fragment.utf8) : Fold.fold(fragment))
        }
        caseSensitive = p.caseSensitive
        fullPath = p.useFullPath
        mode = p.matchMode
        var textLiteral: [UInt8] = []
        if !p.text.isEmpty {
            hasText = true
            needle = Bytes(caseSensitive ? Array(p.text.utf8) : Fold.fold(p.text))
            switch mode {
            case .regex:
                if let compiled = try? NSRegularExpression(pattern: p.text, options: caseSensitive ? [] : [.caseInsensitive]) {
                    regex = Unmanaged.passRetained(compiled)
                } else {
                    mode = .substring
                }
            default: break
            }
            if !fullPath {
                let folded = Fold.fold(p.text)
                switch mode {
                case .substring, .exact, .prefix, .suffix, .wordsOnly:
                    textLiteral = folded
                case .wildcard:
                    // Longest run between wildcards must appear somewhere in the name.
                    var run: [UInt8] = [], best: [UInt8] = []
                    for b in folded + [UInt8(ascii: "*")] {
                        if b == UInt8(ascii: "*") || b == UInt8(ascii: "?") {
                            if run.count > best.count { best = run }
                            run = []
                        } else {
                            run.append(b)
                        }
                    }
                    textLiteral = best
                case .regex:
                    break
                }
            }
        }
        literal = Bytes(textLiteral.count >= extLiteral.count ? textLiteral : extLiteral)
    }

    func release() {
        ext?.free()
        pathFragment?.free()
        needle.free()
        literal.free()
        under?.release()
        parents?.release()
        regex?.release()
    }

    @inline(__always) func matches(_ id: Int, plan: Plan, ctx: inout EvalContext) -> Bool {
        let store = plan.store
        if hasFilesOnly && filesOnly == store.isDirectory(id) { return false }
        if let ext, !Term.extensionInList(store.folded(id), ext.buffer) { return false }
        if bytes != nil || changed != nil || made != nil || hasBlank {
            let meta = store.meta(id)
            if let bytes, !bytes.matches(Int64(meta.size)) { return false }
            if let changed, !changed.matches(Double(meta.mtime)) { return false }
            if let made, !made.matches(Double(meta.ctime)) { return false }
            if hasBlank {
                let dir = store.isDirectory(id)
                if blank {
                    if dir || meta.size != 0 { return false }
                } else if !dir || meta.size == 0 {
                    return false
                }
            }
        }
        if hasText && !fullPath {
            if !matchText(caseSensitive ? store.raw(id) : store.folded(id), store: store, id: id) { return false }
        }
        if let under, !under._withUnsafeGuaranteedRef({ $0.contains(id, store: store) }) { return false }
        if let parents, !parents._withUnsafeGuaranteedRef({ $0.containsParent(of: id, store: store) }) { return false }
        if let level, !level.matches(Int64(store.depth(id))) { return false }
        if let chars, !chars.matches(Int64(String(decoding: store.raw(id), as: UTF8.self).count)) { return false }
        if let fragment = pathFragment, !ctx.pathContains(id, fragment.buffer, folded: !pathCaseSensitive, plan: plan) {
            return false
        }
        if hasText && fullPath {
            if mode == .substring {
                if !ctx.pathContains(id, needle.buffer, folded: !caseSensitive, plan: plan) { return false }
            } else {
                ctx.fullPath(of: id, folded: !caseSensitive, plan: plan)
                if !ctx.scratch.withUnsafeBufferPointer({ matchText($0, store: store, id: id, path: true) }) { return false }
            }
        }
        if let touched, !touched.matches(plan.accessTime(id).timeIntervalSince1970) { return false }
        return true
    }

    @inline(__always)
    private func matchText(_ hay: UnsafeBufferPointer<UInt8>, store: IndexStore, id: Int, path: Bool = false) -> Bool {
        let n = needle.buffer
        switch mode {
        case .substring:
            return Term.contains(hay, n)
        case .exact:
            return IndexStore.compare(hay, n) == 0
        case .prefix:
            return hay.count >= n.count && IndexStore.compare(UnsafeBufferPointer(rebasing: hay[0..<n.count]), n) == 0
        case .suffix:
            return hay.count >= n.count
                && IndexStore.compare(UnsafeBufferPointer(rebasing: hay[(hay.count - n.count)...]), n) == 0
        case .wildcard:
            return Term.glob(n, hay)
        case .wordsOnly:
            return Term.containsWord(hay, n)
        case .regex:
            guard let regex else { return false }
            let text = path ? store.path(id) : String(decoding: store.raw(id), as: UTF8.self)
            return regex._withUnsafeGuaranteedRef {
                $0.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
            }
        }
    }

    // MARK: Byte helpers

    @inline(__always) static func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Bool {
        if needle.isEmpty { return true }
        guard let base = hay.baseAddress, hay.count >= needle.count else { return false }
        return memmem(base, hay.count, needle.baseAddress!, needle.count) != nil
    }

    @inline(__always) static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 0x80
    }

    static func containsWord(_ hay: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !needle.isEmpty, let base = hay.baseAddress, hay.count >= needle.count else { return false }
        var start = 0
        while start + needle.count <= hay.count {
            guard let found = memmem(base + start, hay.count - start, needle.baseAddress!, needle.count)
            else { return false }
            let at = UnsafeRawPointer(found) - UnsafeRawPointer(base)
            let before = at == 0 || !isWordByte(hay[at - 1])
            let after = at + needle.count == hay.count || !isWordByte(hay[at + needle.count])
            if before && after { return true }
            start = at + 1
        }
        return false
    }

    /// `*` any run, `?` one UTF-8 scalar; whole-string match.
    static func glob(_ pattern: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>) -> Bool {
        var p = 0, t = 0
        var star = -1, mark = 0
        @inline(__always) func scalarEnd(_ i: Int) -> Int {
            var j = i + 1
            while j < text.count && text[j] & 0xC0 == 0x80 { j += 1 }
            return j
        }
        while t < text.count {
            if p < pattern.count && pattern[p] == UInt8(ascii: "?") {
                p += 1
                t = scalarEnd(t)
            } else if p < pattern.count && pattern[p] == UInt8(ascii: "*") {
                star = p
                p += 1
                mark = t
            } else if p < pattern.count && pattern[p] == text[t] {
                p += 1
                t += 1
            } else if star >= 0 {
                p = star + 1
                mark = scalarEnd(mark)
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == UInt8(ascii: "*") { p += 1 }
        return p == pattern.count
    }

    /// Same rule as `NSString.pathExtension`: text after the last dot, empty when the
    /// dot ends the name or only dots precede it.
    static func extensionRange(_ name: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot + 1 < name.count else { return nil }
        var onlyDots = true
        for i in 0..<dot where name[i] != UInt8(ascii: ".") { onlyDots = false; break }
        return onlyDots ? nil : (dot + 1)..<name.count
    }

    /// Extension equals one of the NUL-separated entries of `list`.
    @inline(__always) static func extensionInList(_ name: UnsafeBufferPointer<UInt8>, _ list: UnsafeBufferPointer<UInt8>) -> Bool {
        var start = 0
        for i in 0...list.count where i == list.count || list[i] == 0 {
            if extensionEquals(name, UnsafeBufferPointer(rebasing: list[start..<i])) { return true }
            start = i + 1
        }
        return false
    }

    @inline(__always) static func extensionEquals(_ name: UnsafeBufferPointer<UInt8>, _ ext: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let range = extensionRange(name) else { return ext.isEmpty }
        return IndexStore.compare(UnsafeBufferPointer(rebasing: name[range]), ext) == 0
    }
}

// MARK: - Folder membership (under:, parent:)

/// Folders selected by `under:` / `parent:`. A value starting with `/` or `~` is an
/// absolute folder; anything else is a folder name matched (folded) anywhere.
private final class Membership {
    private var targets = Set<Int>()
    private var member: [Bool] = []   // by id, folders only meaningful
    private let includeTargets: Bool

    init(target: String, store: IndexStore, includeTargets: Bool) {
        self.includeTargets = includeTargets
        if target.hasPrefix("/") || target.hasPrefix("~") {
            let path = Scanner.standardize(target)
            if let id = store.resolve(path), store.isDirectory(id) { targets.insert(id) }
        } else {
            let key = Fold.fold(target)
            for id in 0..<store.count where store.isDirectory(id) && !store.isDead(id)
                && IndexStore.equal(store.folded(id), key) {
                targets.insert(id)
            }
            // Roots store their full path; match their last component too.
            for r in 0..<store.rootCount where Fold.fold((store.meta.roots[r] as NSString).lastPathComponent) == key {
                targets.insert(r)
            }
        }
        guard includeTargets else { return }
        // member[folder] = folder is a target or lies below one (memoised walk up).
        member = Array(repeating: false, count: store.count)
        var known = Array(repeating: false, count: store.count)
        for id in 0..<store.count where store.isDirectory(id) && !known[id] {
            var chain: [Int] = []
            var cursor = id
            var result = false
            while cursor >= 0 {
                if known[cursor] { result = member[cursor]; break }
                if targets.contains(cursor) { result = true; known[cursor] = true; member[cursor] = true; break }
                chain.append(cursor)
                cursor = store.parent(cursor)
            }
            for node in chain {
                known[node] = true
                member[node] = result
            }
        }
    }

    /// Entry is a target folder or anywhere below one.
    func contains(_ id: Int, store: IndexStore) -> Bool {
        if store.isDirectory(id) { return id < member.count && member[id] }
        let p = store.parent(id)
        return p >= 0 && p < member.count && member[p]
    }

    /// Entry's direct parent is a target folder.
    func containsParent(of id: Int, store: IndexStore) -> Bool {
        let p = store.parent(id)
        return p >= 0 && targets.contains(p)
    }
}

// MARK: - Ordering

private struct Order {
    let before: (Int, Int) -> Bool
    /// Keys too expensive to compare inside the heap: collect everything, sort once.
    let collectsAll: Bool
    let finalize: ([Int]) -> [Int]

    init(key: SortKey, ascending: Bool, plan: Plan) {
        let store = plan.store
        func byName(_ a: Int, _ b: Int) -> Int {
            let c = IndexStore.compare(store.folded(a), store.folded(b))
            if c != 0 { return c }
            let r = IndexStore.compare(store.raw(a), store.raw(b))
            return r != 0 ? r : a - b
        }
        func directed(_ c: Int) -> Bool { ascending ? c < 0 : c > 0 }
        func numeric<T: Comparable>(_ x: T, _ y: T, _ a: Int, _ b: Int) -> Bool {
            if x != y { return ascending ? x < y : x > y }
            return byName(a, b) < 0
        }
        switch key {
        case .name:
            before = { directed(byName($0, $1)) }
            collectsAll = false
        case .size:
            before = { numeric(store.size($0), store.size($1), $0, $1) }
            collectsAll = false
        case .modified:
            before = { numeric(store.mtime($0), store.mtime($1), $0, $1) }
            collectsAll = false
        case .created:
            before = { numeric(store.meta($0).ctime, store.meta($1).ctime, $0, $1) }
            collectsAll = false
        case .level, .path, .fileExtension, .accessed:
            before = { _, _ in false }
            collectsAll = true
        }
        let direction = ascending
        switch key {
        case .path:
            finalize = { ids in
                var buffer: [UInt8] = []
                let keyed = ids.map { id -> ([UInt8], Int) in plan.pathBytes(id, folded: true, into: &buffer); return (buffer, id) }
                return keyed.sorted { a, b in
                    let c = a.0.withUnsafeBufferPointer { x in b.0.withUnsafeBufferPointer { IndexStore.compare(x, $0) } }
                    return c != 0 ? (direction ? c < 0 : c > 0) : a.1 < b.1
                }.map(\.1)
            }
        case .fileExtension:
            finalize = { ids in
                ids.sorted { a, b in
                    let fa = store.folded(a), fb = store.folded(b)
                    let ea = Term.extensionRange(fa).map { UnsafeBufferPointer(rebasing: fa[$0]) } ?? UnsafeBufferPointer(start: nil, count: 0)
                    let eb = Term.extensionRange(fb).map { UnsafeBufferPointer(rebasing: fb[$0]) } ?? UnsafeBufferPointer(start: nil, count: 0)
                    let c = IndexStore.compare(ea, eb)
                    return c != 0 ? (direction ? c < 0 : c > 0) : byName(a, b) < 0
                }
            }
        case .level:
            finalize = { ids in
                ids.map { ($0, store.depth($0)) }.sorted { a, b in
                    a.1 != b.1 ? (direction ? a.1 < b.1 : a.1 > b.1) : byName(a.0, b.0) < 0
                }.map(\.0)
            }
        case .accessed:
            finalize = { ids in
                ids.map { ($0, plan.accessTime($0)) }.sorted { a, b in
                    a.1 != b.1 ? (direction ? a.1 < b.1 : a.1 > b.1) : byName(a.0, b.0) < 0
                }.map(\.0)
            }
        default:
            let ordered = before
            finalize = { $0.sorted(by: ordered) }
        }
    }
}

/// Keeps the `limit` best ids under `before` (max-heap on "worst kept").
private struct TopK {
    let limit: Int
    let before: (Int, Int) -> Bool
    private(set) var items: [Int] = []

    init(limit: Int, before: @escaping (Int, Int) -> Bool) {
        self.limit = limit
        self.before = before
    }

    mutating func insert(_ id: Int) {
        if limit == Int.max { items.append(id); return }
        guard limit > 0 else { return }
        if items.count < limit {
            items.append(id)
            siftUp(items.count - 1)
        } else if before(id, items[0]) {
            items[0] = id
            siftDown(0)
        }
    }

    // Heap order: parent is "worse" (comes later) than children.
    private mutating func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let p = (i - 1) / 2
            if before(items[p], items[i]) { items.swapAt(p, i); i = p } else { break }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var i = index
        while true {
            let l = 2 * i + 1, r = l + 1
            var worst = i
            if l < items.count && before(items[worst], items[l]) { worst = l }
            if r < items.count && before(items[worst], items[r]) { worst = r }
            if worst == i { return }
            items.swapAt(i, worst)
            i = worst
        }
    }
}
