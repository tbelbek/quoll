# Roadmap

Quoll exists for one job: instant filename search over the whole home folder,
dot-folders included (Spotlight drops every path under a dot-folder, even after
`mdimport`). The roadmap is built around doing that job with the least time,
memory, disk and battery. Everything else is in **Later**.

Personal use on two Macs (MacBook Air with heavy memory pressure, MacBook Pro).
No distribution, no team features.

## Where we are (measured 2026-11-20, MacBook Air, release build)

| Metric | Quoll 1.0 (`~/Repos`, 734k) | C prototype (`~/Repos`, 745k) | C prototype (home, 2.30M) | Target (home, 2.3M) |
|---|---|---|---|---|
| Full scan | 26 s | 1.0 s (4 threads) | 9.2 s (6 threads) | < 12 s |
| Peak RSS during scan | 2.3 GB | 57 MB | 171 MB | < 300 MB |
| Steady RSS | 1.25 GB | – | – | < 250 MB, mostly clean mmap pages |
| Catalog on disk | 247 MB JSON | – | – | < 180 MB |
| Cold start to first query | ~3 s | – | – | < 1 s |
| Substring query | 1,190 ms | 1.1 ms | 3.5 ms | p95 < 15 ms |
| Empty query / newest first | 4,500 ms | 0.6 ms | 1.5 ms | < 5 ms |
| Idle disk writes | catalog rewritten every ~2 s (see M1) | – | – | none |

The prototype is a parallel `getattrlistbulk` walk into flat arrays (an
ASCII-folded, NUL-separated name arena plus offset and mtime columns) and a
parallel `memmem` over the arena. It stores less than the real catalog will
(no parent, size, flags or display names), so its memory figures are a floor.
Threads beyond 6 made the walk slower (10 threads: 1.41 s on `~/Repos`).

Conclusions the plan rests on:

- `getattrlistbulk` with 4–6 workers is ~25x faster than the current
  `FileManager` walk and ~10x faster than `fd`.
- Flat columns cut memory 15–20x against `[String: FileEntry]`.
- A pre-folded byte arena with parallel `memmem` is already instant at 2.3M
  entries. **No trigram or suffix index in v1**; build one only if M3 misses
  its target.
- Newest-first needs no presorted order: one pass over the `mtime` column with a
  bounded top-K takes 1.5 ms at 2.3M.
- Default excludes (`.git`, `node_modules`) only take 2.3M down to 1.83M.
  Size the design for 2.3M; excludes are about battery and noise, not memory.

## Status (2026-11-20)

M0–M4 are done; measurements and the decisions taken on the way are in
[DECISIONS.md](DECISIONS.md). Against the targets at 2.3M entries: scan 11.7 s,
peak RSS 50 MB, snapshot 170 MB, cold start 3.4 ms, footprint 2–4 MB idle and
≤ 17 MB while querying, substring p95 < 6 ms, empty query newest-first p95
< 5 ms; replay of 10k offline changes in ~1.5 s without a rescan. Below `path:`
(~50 ms at 2.3M) every query is well under target.

## M0 — Benchmark and oracle

- `quoll-selftest --bench <root>` prints one TSV row: scan s, peak RSS
  (`getrusage`), snapshot bytes, load ms, and p50/p95 over a fixed query set
  (empty, `kanelbulle`, `*.md`, `ending:md`, `path:.config json`, each sorted by
  name and by modified).
- Oracle: entry count equals `fd --hidden --no-ignore` on the same root, and the
  single-thread and parallel matchers return the same hits.
- Run: `/usr/bin/time -l .build/release/quoll-selftest --bench ~/Repos`.
  Every later milestone is accepted against this output.

## M1 — Stop the waste (current store, small diffs)

Fixes that survive the rewrite, shipped first because they make 1.0 usable.

- **Save loop (verified).** The catalog lives in
  `~/Library/Application Support/Quoll`, inside the default root. Each save
  raises an FSEvents batch, `applyChanges` always schedules a save
  (`Service.swift:160-161`), and the catalog is rewritten every ~2 s forever
  (9 writes in 20 s with nothing changing). Fix: exclude the data directory,
  create the stream with `kFSEventStreamCreateFlagIgnoreSelf`, and persist
  only when a batch changed something.
- **Excludes that work.** Today a plain name like `node_modules` is resolved
  against the cwd, a glob without `/` excludes the folder but not its children,
  and excluded folders are still walked (`Scanner.swift:113,133-173`). Fix:
  name rules match any path component, an excluded directory calls
  `skipDescendants`, and the watcher uses the same normalised list
  (`Service.swift:148,155`). Ship defaults: `.git`, `node_modules`, `.Trash`,
  `.cache`, `~/Library/Caches`, `~/Library/CloudStorage`, the data directory.
- **No silently stale catalog.** Rescan in the background on every start (a
  stopgap until M4) and drop `--no-scan` from `scripts/install-agent.sh`.
- Accept: zero catalog writes during 10 idle minutes (`fs_usage`);
  `node_modules/a/b.js` is neither indexed nor walked (self-test).

## M2 — Column store, snapshot and the new scanner

Replaces `Catalog`, `FileEntry` storage, `catalog.json` and `Scanner` together.
The scanner writes the columns directly, so doing them apart would mean a
throwaway adapter.

- **Columns by entry id:** `parent: u32`, `nameOff: u32`, `mtime: u32`,
  `size: u64`, `flags: u8` (dir, symlink, has-display-name, tombstone).
  A folded-name arena for matching and a display-name arena for output. The
  full path is rebuilt from the parent chain, only for rows being shown.
  Dropped: `accessed` (no events on atime, always stale), `level`, `mount`,
  `fileExtension` (all derivable).
- **Lookups:** hash of (parent id, folded name) → id, and inode → id for
  directories only.
- **Subtree delete:** tombstone the directory, then one forward pass over
  `parent` marks children dead. No string comparisons. A directory rename or
  move is one `parent`/name rewrite.
- **Snapshot:** one binary file with page-aligned columns, `mmap`ed read-only,
  so its pages stay clean and the kernel can drop them under pressure instead
  of swapping. The header holds the format version, the FSEvents event ID and
  the volume UUID. Changes go to a small heap delta: appended entries, a
  tombstone bitset, and an id → (mtime, size) override map for base entries.
  Compaction is writing the next snapshot (on quit, and when idle after N
  changes). A version mismatch is a rescan, never a migration.
  No journal: FSEvents history replays whatever the snapshot missed (M4).
  Revisit only if risk 1 fails.
- **Scanner:** `getattrlistbulk` per directory (`NAME`, `OBJTYPE`, `MODTIME`,
  `FILEID`, `FLAGS`, `DATALENGTH`), shared directory stack, fixed pool of
  `min(6, performance cores)` workers. Prune excluded directories before
  descending. Skip dataless directories by flag (`SF_DATALESS`) and call
  `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
  IOPOL_MATERIALIZE_DATALESS_FILES_OFF)` so a walk never triggers a download.
  Stay on the root's device. Symlinks are listed, never followed.
- **Off the hot path:** the scan runs in the background, the control server
  starts first (`Service.swift:38-49` blocks today), `status` reads counters
  instead of walking every entry, and a running `rebuild` replies immediately
  and reports progress through `status`.
- Accept: scan, peak RSS, steady RSS, snapshot and cold-start targets above.
  Self-test: snapshot round trip; deleting a 100k-entry subtree < 5 ms;
  rename is O(1).

## M3 — Search engine

- **Folding, once at index time and once per query:** NFD, strip combining
  marks, lowercase, `ı` → `i`, stored as UTF-8. Locale-independent, so
  `İ`, `I`, `ı` and `i` all match. ASCII fast path for the common case.
- **Matching:** for a single literal, `memmem` across whole arena chunks,
  mapping hit offsets back to ids. Per-entry matching only when several text
  predicates combine. Cheap column predicates (kind, size, mtime) run first.
  Chunks are split across performance cores with `concurrentPerform`.
- **Ordering:** bounded top-K heap. Newest first uses the `mtime` column; name
  order compares folded bytes. No presorted permutations.
- **Query language, parser unchanged:**
  - `ending:x` — suffix test on the folded name.
  - Wildcards — anchored prefix and suffix plus ordered `memmem` of the middle
    pieces; `?` uses a small scalar glob.
  - `pattern:` — `NSRegularExpression` on the display name, only on entries
    that survive the other predicates (target < 300 ms).
  - `under:` — subtree bitset from one pass over `parent`. A bare name such as
    `under:src` matches folders with that name, not a path relative to the
    process cwd (`Language.swift:285-288` today).
  - `path:` — bitset of matching directories, then test the parent bit or the
    entry's own name.
- **Cancellation:** a generation counter checked per chunk, so a newer
  keystroke abandons the older query. The app's 150 ms debounce goes to zero.
- Accept: p95 < 15 ms substring and < 5 ms empty query at 2.3M; results equal
  the 1.0 engine on `~/Repos`; `irmak` finds `ırmak.txt`, `istanbul` finds
  `İSTANBUL`.
- Fallback, only if the target is missed: trigram index over the folded arena.

## M4 — Durable change tracking

- Start the stream at the snapshot's event ID (`sinceWhen`) when
  `FSEventsCopyUUIDForDevice` matches; otherwise rescan.
- Flags: `FileEvents | UseExtendedData | IgnoreSelf | WatchRoot`, latency 1 s.
- Do not trust per-item flags (they coalesce). For each event path: drop it if
  any component is excluded, then `lstat`. Absent → remove the subtree. File →
  upsert. Directory with a known inode → reparent. Unknown directory → scan
  that subtree. An event on an existing directory no longer rescans it
  recursively (today a metadata change on `~` rescans the whole home,
  `Service.swift:141-153`).
- `MustScanSubDirs` → rescan that subtree. `UserDropped`, `KernelDropped`,
  `RootChanged`, `EventIdsWrapped` → full background rescan. `HistoryDone`
  marks the catalog current.
- Accept: quit, create/delete/rename 10k files, start again; within 5 s the
  catalog equals a fresh scan, without a full rescan.

## Later (second priority)

Done in 0.2.0:

- [x] Native window: Name / Folder / Size / Modified, newest first, header sort,
      Enter opens, ⌘Enter reveals, ⌘C copies paths; movable, full screen, Esc hides.
- [x] Global hotkey (`RegisterEventHotKey`), `hyper+s` default, `super+s` for
      Caps-Lock super-key tools; settings window.
- [x] One process: the menu-bar app hosts the service.
- [x] Stable self-signed code signing (`scripts/make-signing-identity.sh`).
- [x] Long-running control commands reply immediately (no 10 s timeout).
- [x] Release tooling: universal zip, CI, tag-driven GitHub releases.

Open:

- [x] Start at login (`SMAppService`), a checkbox in Settings (0.2.1).
- [x] Quick Look on ⌘Y (0.3.0).
- [ ] HTTP bound to loopback only; drop Basic auth and static file serving.
- [ ] Reject control paths longer than `sun_path` (104 bytes) with a clear error.
- [x] Dates name whole periods: `changed:2025` is the year (0.3.0).
- [x] `path:` caches the parent path per run of siblings: 275 → ~45 ms at 1.1M (0.3.0).
- [x] Match highlighting; Created and Kind columns (header menu) (0.3.0).
- [x] Quick filters (⌘1–⌘8), recent and saved searches, Open With / Terminal /
      Rename / Trash, exclude a folder from a result (0.4.0).
- [x] External drives: an index per mounted drive, replayed on reattach (0.4.0).
- [x] Homebrew tap: `brew install --cask tbelbek/quoll/quoll` (0.4.0).
- [x] Hotkey recorder; scopes (`scope:user`, user-defined); Opened count + sort;
      folder sizes; index statistics; Finder service and `quoll://` URLs;
      incremental rule changes (0.5.0).
- [ ] Developer ID signing + notarization (needs an Apple Developer account).

## Cut / defer

| Item | Reason |
|---|---|
| Team catalogs, ACLs, query subscriptions | Single user |
| Linux port | Personal Macs only |
| Stable file-format spec and migration tool | The catalog is disposable; a version bump means a rescan |
| Remote source, plugin protocol | No second instance, no plugin author |
| Content search, duplicate detection, saved lists, CSV import | Not filename search |
| Incremental journal, prefix buckets, memory-mapped name table | Replaced by the M2 snapshot + FSEvents replay and the M3 arena |
| `touched:` / access time | atime raises no events, so the value is always stale |

## Risks to test on macOS 27 first

1. How far back FSEvents replays after days of sleep before IDs are purged.
   The no-journal decision depends on this.
2. Whether `UseExtendedData` delivers file IDs on replayed events or only on
   live ones.
3. What `getattrlistbulk` returns for dataless iCloud / CloudStorage
   directories with materialisation off: an error or an empty listing.
4. Whether `IgnoreSelf` covers writes done through an atomic rename.
5. Whether a self-signed designated requirement keeps Full Disk Access across
   rebuilds.
6. Folding cost: the prototype folds ASCII only. Measure the Unicode path in
   M3 before relying on the scan target.
7. A 9–12 s scan on battery is a visible burst. It must only happen on first
   run or after an event-ID gap, which M4 guarantees.

## Docs to fix alongside

- `README.md:4` claims millisecond answers (measured 1.2–4.5 s); `README.md:25`
  says Swift 6 while `Package.swift:1` is tools-version 5.9; the quick start's
  bare `quoll scan` walks the whole home plus `/Applications` with no excludes.
- `ARCHITECTURE.md:27` says the scanner handles excludes; `:57-58` says the
  socket is the only local API (the CLI reads the catalog directly and the app
  can run the service in-process); `:79-80` says mutating commands go through
  `stateQueue` (`forget` does not, `Service.swift:255`).
- `QUERY.md`: `under:`/`parent:` resolve against the cwd; `bytes:0` returns
  folders; `ı` is not folded; wildcard, `word:` and `pattern:` are not
  diacritic-insensitive (`Language.swift:726`); `chars:` and `plain:` are
  undocumented; a CLI query starting with `-` needs `--`.
- `PROTOCOL.md:99` documents an HTTP `offset` that is never read
  (`Service.swift:325-334`); `:78` lists an `internal` error code that does not
  exist; `:30` says `scan` replaces the catalog, but with empty `paths` it
  merges; `:4` says the socket is created 0600, but it is chmod-ed after bind.
- CLI: `--sort extension` silently falls back to name (the raw value is
  `fileExtension`, `Entry.swift:86`); the "no index" error suggests a
  nonexistent `quoll index` (`main.swift:163,327`).
