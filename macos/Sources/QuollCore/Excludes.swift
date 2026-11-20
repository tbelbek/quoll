import Foundation

/// Exclude and include rules shared by the scanner and the change watcher.
///
/// Rule syntax (both lists):
/// - No `/`: matches one path component anywhere (`node_modules`, `*.tmp`).
/// - Starts with `~` or contains `/`: an absolute path and its subtree. Globs
///   are allowed (`fnmatch`, `*` spans `/`).
///
/// Precedence: hard excludes (Quoll's own data directory) > includes > excludes.
/// An include under an excluded folder makes the walker pass *through* that
/// folder (the folder itself is indexed, its other children are not).
public struct ExcludeRules: Sendable {
    /// Shipped defaults; measured on the owner's home (2026-11-20): `.git` and
    /// `node_modules` hold 440k of 1.89M non-Library entries, `~/Library/Caches` 162k.
    public static let defaults = [
        ".git", "node_modules", ".Trash", ".cache",
        "~/Library/Caches", "~/Library/CloudStorage"
    ]

    public enum Verdict: Sendable, Equatable {
        /// Index it; children are evaluated normally.
        case keep
        /// Excluded directory that leads to an include: index it and walk it,
        /// but its children inherit the exclusion.
        case passThrough
        /// Do not index, do not descend.
        case skip
    }

    private struct RuleSet: Sendable {
        var names: Set<String> = []
        var nameGlobs: [String] = []
        var paths: [String] = []
        var pathGlobs: [String] = []

        init(_ rules: [String]) {
            for raw in rules {
                let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rule.isEmpty else { continue }
                let isGlob = rule.contains("*") || rule.contains("?") || rule.contains("[")
                if rule.hasPrefix("~") || rule.contains("/") {
                    let expanded = (rule as NSString).expandingTildeInPath
                    if isGlob {
                        pathGlobs.append(expanded)
                    } else {
                        var path = URL(fileURLWithPath: expanded).standardizedFileURL.path
                        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                        paths.append(path)
                    }
                } else if isGlob {
                    nameGlobs.append(rule)
                } else {
                    names.insert(rule)
                }
            }
        }

        var isEmpty: Bool { names.isEmpty && nameGlobs.isEmpty && paths.isEmpty && pathGlobs.isEmpty }
        var hasNameRules: Bool { !names.isEmpty || !nameGlobs.isEmpty }

        func matchesName(_ name: String) -> Bool {
            if names.contains(name) { return true }
            for glob in nameGlobs where fnmatch(glob, name, 0) == 0 { return true }
            return false
        }

        func matchesPath(_ path: String) -> Bool {
            for prefix in paths where path == prefix || path.hasPrefix(prefix + "/") { return true }
            for glob in pathGlobs where fnmatch(glob, path, 0) == 0 { return true }
            return false
        }
    }

    private let excludes: RuleSet
    private let includes: RuleSet
    private let hard: RuleSet

    public init(_ excludes: [String], includes: [String] = [], alwaysExcluded: [String] = []) {
        self.excludes = RuleSet(excludes)
        self.includes = RuleSet(includes)
        self.hard = RuleSet(alwaysExcluded)
    }

    public var isEmpty: Bool { excludes.isEmpty && hard.isEmpty }

    /// Verdict for one entry met during a walk. `inheritedExclusion` is true for
    /// children of a `.passThrough` directory.
    ///
    /// `checkPaths: false` skips every path rule; pass it only when
    /// `needsPaths(below:)` is false for the entry's folder.
    public func verdict(name: String, path: String, isDirectory: Bool, inheritedExclusion: Bool = false,
                        checkPaths: Bool = true) -> Verdict {
        if checkPaths && hard.matchesPath(path) { return .skip }
        if includes.matchesName(name) || (checkPaths && includes.matchesPath(path)) { return .keep }
        let excluded = inheritedExclusion || excludes.matchesName(name) || (checkPaths && excludes.matchesPath(path))
        if !excluded { return .keep }
        if checkPaths && isDirectory && leadsToInclude(path) { return .passThrough }
        return .skip
    }

    /// Can any path rule match an entry directly inside `folder`? When false the
    /// walker skips building per-entry path strings.
    public func needsPaths(below folder: String) -> Bool {
        if !excludes.pathGlobs.isEmpty || !includes.pathGlobs.isEmpty || !hard.pathGlobs.isEmpty { return true }
        let prefix = folder == "/" ? "/" : folder + "/"
        return excludes.paths.contains { $0.hasPrefix(prefix) }
            || includes.paths.contains { $0.hasPrefix(prefix) }
            || hard.paths.contains { $0.hasPrefix(prefix) }
    }

    /// Stable text form, stored in the snapshot to detect rule changes.
    public var fingerprint: String {
        func f(_ r: RuleSet) -> String {
            (r.names.sorted() + r.nameGlobs + r.paths + r.pathGlobs).joined(separator: "\u{1f}")
        }
        return [f(excludes), f(includes), f(hard)].joined(separator: "\u{1e}")
    }

    /// Convenience for callers that only need yes/no (files, or a walk without includes).
    public func excludes(name: String, path: String) -> Bool {
        verdict(name: name, path: path, isDirectory: false) == .skip
    }

    /// Is an arbitrary absolute path outside the index? Used for watcher events,
    /// where the ancestors have not been checked yet.
    public func excludesAnyComponent(of path: String) -> Bool {
        if hard.matchesPath(path) { return true }
        if includes.matchesPath(path) { return false }
        if excludes.matchesPath(path) { return !leadsToInclude(path) }
        guard excludes.hasNameRules else { return false }
        var prefix = ""
        for component in path.split(separator: "/") {
            let name = String(component)
            prefix += "/" + name
            if excludes.matchesName(name) && !includes.matchesName(name) {
                // Excluded ancestor: only an include at or below this point saves it.
                if includes.matchesPath(path) { return false }
                return !(prefix == path && leadsToInclude(path))
            }
        }
        return false
    }

    /// Some include path lies strictly below `path`.
    private func leadsToInclude(_ path: String) -> Bool {
        let prefix = path + "/"
        return includes.paths.contains { $0.hasPrefix(prefix) }
            || includes.pathGlobs.contains { $0.hasPrefix(prefix) }
    }
}
