# Decisions

Measured decisions taken while implementing the roadmap. Each entry: what was
decided, the measurement behind it, and what would make us revisit it.
Machine: MacBook Air (Apple Silicon, 24 GB, swap ~19/20 GB used), macOS 27.

## D1 — Default excludes (2026-11-20)

`.git`, `node_modules`, `.Trash`, `.cache`, `~/Library/Caches`,
`~/Library/CloudStorage`, plus Quoll's data directory (hard, not overridable).

- Home holds ~2.3M entries; 1.89M are outside `~/Library`, of which 440k sit in
  `.git` / `node_modules`. `~/Library` is ~400k, the largest part `Caches` (162k),
  then `Application Support` (151k).
- `~/Library` as a whole stays indexed: apart from `Caches` it is small and
  occasionally searched (app support files, preferences).
- Revisit if the owner misses results from an excluded area: `includes` overrides
  any exclude (`quoll settings --include PATH|NAME`), and
  `--no-default-excludes` turns the defaults off.

## D2 — Includes override excludes; the data directory cannot be included

Precedence: hard excludes > includes > excludes. An include below an excluded
folder makes the walker pass through that folder (the folder is indexed, its
other children are not). Indexing the data directory would re-create the
save loop (M1), so it is excluded unconditionally.

## D3 — M1 result on the old walker

`~/Repos` with default excludes: 380k entries (from 734k), 13.5 s, 1.14 GB peak
RSS, 124 MB JSON. Target "< 10 s" missed: the `FileManager` walker itself is the
bottleneck (prototype: ~1 s for the same tree). Accepted, because M2 replaces the
walker; the save loop fix (9 writes / 20 s idle → 0) is the part that matters.

## D4 — Scanner: `getattrlistbulk`, 4 workers

Home with default excludes (1.11M entries), same machine, warm cache:

| Workers | Scan | CPU (user+sys) | Peak footprint |
|---|---|---|---|
| 2 | 14.1 s | – | 24 MB |
| 4 | 6.8–8.5 s | 8.3 s | 28–32 MB |
| 6 | 6.8 s | – | 34 MB |
| 8 | 5.1–5.6 s | 11.3 s | 37 MB |

8 workers scan 26% faster but burn 37% more CPU (kernel contention) and 9 MB
more footprint. Footprint and battery win: 4 workers (`BulkScanner.defaultThreads`).
Full scans only happen on first run or after an FSEvents gap.

## D5 — Two full name arenas (folded + display), both mapped

1.1M names: 76% unchanged by folding, 100% ASCII, 24.5 MB per arena. Storing
display names only where they differ would save ~18 MB of *disk*, but mapped
pages are clean and do not count toward footprint, and the sparse variant needs
an id → offset index plus a second code path. Kept both arenas complete.

## D6 — Keep the parent column, `size u64`, a `ctime` column

Clean mapped columns cost disk, not footprint. Dropping `parent` (9 MB at 2.3M)
would have required binary searches over folder ranges and breaks after a
folder move. `ctime` makes `made:` a column test instead of 2.3M `lstat` calls.
`atime` is not stored (no events on access; always stale): `touched:` and the
`accessed` sort use `lstat` on candidates only.

## D7 — Query evaluation without ARC; exclusivity checks off in QuollCore

Profile of the first engine (`sample`, `*.md` over 1.1M entries): >90% of
samples in `swift_retain`/`swift_release` from copying a `Term` struct holding
arrays, classes and Foundation `Date` per entry, contended across 10 threads.
Flattening the query into reference-free buffers (`FlatNode`, `Term` with raw
pointers, `SecondsRule` instead of `Date`) took `*.md` from 340 ms to 4.6 ms.
Then A/B over the full query set, 3 runs each: `-enforce-exclusivity=unchecked`
on QuollCore is 10–15% faster, most on the empty query (2.5–3.7 ms vs 4.5–5.3 ms
at 2.3M). Safe here because every mutation runs on one queue under the store's
write lock.

## D8 — Literal driver for per-entry queries

Every term yields a literal its folded name must contain (substring/prefix/
suffix/exact/word: the needle; wildcard: the longest run between `*`/`?`;
`ending:x`: `.x`). The longest literal among the root term or the root AND's
terms drives a `memmem` over the name arena; only hits are evaluated.
`ending:md` 416 ms → 4.3 ms, `report draft` 415 ms → 3.0 ms. No trigram index.

## D9 — No `UseExtendedData` in the FSEvents stream

Folder moves are detected from `lstat`'s inode against the folder inode table,
so per-event file ids add nothing. Fewer moving parts, no dependency on risk 2.

## D10 — Compaction policy

Snapshot rewrite (streamed; measured 0.4 s for 1.1M entries, 0.8 s for 2.3M)
happens on shutdown, when
the overlay reaches 20,000 changes, or after 5 idle minutes once the snapshot is
6 hours old. Writing ~90 MB after every small batch would make idle disk writes
non-zero; between snapshots a crash only means a longer FSEvents replay, which
is idempotent (reconcile by `lstat`).

## M2/M3 results (2026-11-20, `quoll-selftest --bench`, fresh process for queries)

| Metric | Home, default excludes (1.11M) | Home, no excludes (2.33M) | Target (2.3M) |
|---|---|---|---|
| Scan (4 workers) | 6.9–7.5 s | 11.7 s | < 12 s ✓ |
| Peak RSS during scan | – | 50 MB | < 300 MB ✓ |
| Snapshot on disk | 86 MB | 170 MB | < 180 MB ✓ |
| Load (cold start) | 2.1 ms | 3.4 ms | < 1 s ✓ |
| Footprint after load | 2.2 MB | 2.2 MB | – |
| Footprint after queries (peak) | 11 MB | 17 MB | < 250 MB ✓ |
| Substring p95 (`kanelbulle`) | 3.1 ms | 4.4–5.8 ms | < 15 ms ✓ |
| Empty query p95, newest first | 4.0 ms | 3.4–4.5 ms | < 5 ms ✓ |
| Empty query p95, by name | 5.3 ms | 4.1–10.9 ms (noisy) | < 5 ms ~ |
| `*.md` p95 | 4.9 ms | 8.2 ms | – |
| `path:` + name (`path:<dot-folder> json`) p95 | 20.8 ms | 46–56 ms | – (path rebuilt per hit) |

Equivalence (`quoll-selftest --equiv ~/Repos`, 380k entries): all 28 queries return
exactly the entries the 1.0 `Matcher` accepts. Run-to-run noise on this machine
is ±20% (swap nearly full).

Known slow spot: `path:` rebuilds the full path for every candidate. A per-folder
memo would fix it; deferred because the owner's priority is footprint and these
queries stay well under 100 ms.

## D11 — Full scans run in a helper process

After a 1.1M-entry scan the service's footprint stayed at 34.6 MB although
`heap` showed ~200 KB of live objects: the scan's malloc churn leaves dirty
pages the allocator keeps, and `malloc_zone_pressure_relief(nil, 0)` returned
nothing. A full scan now runs in the service's own executable started with
`--quoll-scan-helper <request.json>`; the child writes the snapshot and exits,
the service maps it. Service footprint after a full home scan: **38 MB → 3.6 MB**
(5.6 MB after a round of queries). In-process fallback if the child cannot start.
Subtree scans after FSEvents changes stay in-process (small).

## D12 — Compaction memory

Compaction peak/residue in a fresh process (1.1M / 2.3M entries): 14.4 / 23.1 MB.
Changes: level-by-level breadth-first walk (only two levels of folders held), one
reused child buffer, folder records streamed in id order, the inode permutation
built from the written (mapped) table, column writer buffers 256 KB → 64 KB.
Result: **6.4 / 8.1 MB**, and faster (0.41 / 0.81 s).

## M4 results (2026-11-20, `quoll-selftest --m4`)

10k new files, 1k deletes, 200 file moves, a folder move, a case-only folder
rename and a folder delete made while Quoll was stopped: on restart the catalog
equals a fresh scan after **1.4–1.6 s**, with no full rescan (FSEvents history
replay). Live changes from another process (500 creates, a folder move, 100
deletes, a new nested folder) converge in **1.4–1.6 s**. A compaction reloads to
the identical tree.

Real service on the owner's home (`quoll serve`, defaults, 1.41M entries): scan
7.4–8.6 s in the helper; 90 s idle with 98 FSEvents batches from normal desktop
activity cost 0.14 s CPU and zero snapshot writes.

Open (roadmap risk 1): replay after days of sleep is untested; a gap that
FSEvents can no longer replay arrives as dropped/wrapped flags and triggers a
full rescan, so it costs time, not correctness.

## D13 — Review fixes: exact lookups, canonical roots, per-root rules

An independent review of M2–M4 found eight defects; each now has a regression
step in `quoll-selftest --m4`:

- Event paths resolve **exactly**; a folded (case/diacritic) match is accepted
  only when it is the same inode (case-only rename). Before, creating
  `resume.txt` renamed or deleted the indexed `résumé.txt`.
- After adding a missing parent folder, the entry is looked up again instead of
  appended a second time (duplicate subtree).
- A `MustScanSubDirs` rescan of a pass-through folder keeps the inherited
  exclusion; the watcher treats every folder on the way to an include as indexed,
  exactly like the walker (it used to drop their events).
- A root that is replaced, deleted or asked to rescan triggers one full scan in
  the helper process instead of being skipped or walked in-process.
- Roots are canonicalised with `realpath` (symlinks, on-disk letter case);
  FSEvents reports real paths.
- Rules are applied relative to each root: exclude rules covering the root are
  dropped and only components below the root are checked, so a root inside an
  excluded area (`~/x/.cache/proj`) is indexed and stays current.
- `scan` over the socket changes roots, store and watcher on the state queue only.
- The scan helper has a 10-minute timeout and falls back to an in-process scan if
  the child crashes; the walker re-checks the device after `open` (mount points);
  folder lookups among newly added children use a name hash (was O(n²)).

## D14 — `path:` without a name literal: parent-path cache, no per-folder memo

`path:Repos/quoll` and `fullpath:src/main` have no literal for the name arena, so
every entry was checked by rebuilding its full path: 275 ms and 310 ms at 1.1M
entries. Siblings sit next to each other in id order, so each scan chunk now keeps
the parent's path and whether it already contains the needle; an entry is then
decided from that flag, or from its own name when the needle has no `/` (if it has
one, the needle's last segment must be a prefix of the name before anything is
copied). Result: ~45 ms and ~42 ms (noisy machine, p50), identical results to the
reference matcher. A per-folder path memo would go further but holds a path per
folder in memory; the footprint priority keeps it out.

## D15 — Window details measured offscreen

The search field clipped descenders with a 15 pt font in a regular (24 pt)
control; rendered offscreen, a large control (28 pt) with the standard 13 pt font
centres the text. Highlighted names use `labelColor` and bold only (no accent
colour, which would vanish on a selected row); checked in light and dark.

## D16 — External drives: one index per volume, attached only while mounted

Each mounted local, writable, browsable, non-internal volume gets its own
`QuollService` (no control socket) with its snapshot under
`<data>/volumes/<volume uuid>`; searches query every index and merge the pages
with the engine's sort order. Indexes stop on `willUnmount`, so they never block an
eject; the snapshot stays on the Mac, and a reattach replays the drive's FSEvents
history. Right after a mount the volume's FSEvents UUID is not available yet
(measured: empty), which failed the snapshot check and forced a rescan on every
reattach; attaching now waits up to 5 s for it. Verified with a writable APFS disk
image (`quoll-selftest --volumes`). Off by default (Settings or
`quoll settings --external-drives on`): a large drive is real scan time and disk.

## D17 — Extension lists in one term

Quick filters need "any of 14 extensions". An OR chain of `ending:` terms
evaluates one term per extension per entry; `ending:pdf;doc;…` is one term whose
extensions sit NUL-separated in a single raw buffer (no reference-counted field in
the hot path, D7). Documents filter on an empty query: ~50 ms at 1.1M entries; any
typed word becomes the memmem driver and brings it back to a few ms.

## D18 — Rule changes without a full scan

Excluding a folder from a result rescanned the whole home (7–12 s). Now a rules
change is diffed: added excludes remove only the entries they match (a path rule
resolves one folder; a name rule checks every live name once) — includes still
win; a removed exclude path or an added include path walks just that folder.
Removed name/glob excludes, removed includes and path globs still rescan (their
effect cannot be located without a walk). The new rules fingerprint is written
with an immediate compaction (~0.5 s), so a restart does not rescan.
`quoll-selftest --m4` checks each case against a fresh scan.

## D19 — `under:` with an absolute folder walks up instead of building a table

`under:` built a membership table over every folder per query (one pass over
1.4M entries); `scope:user` has two such terms, so `scope:user ending:md` took
290 ms. For one absolute folder, each candidate now walks its parents (~10 steps)
and only driver hits are candidates: 18 ms. Folder-name targets (`under:src`) keep
the table, since all folders with that name must be found anyway.

## D20 — Open counts live with the index, not the UI

`opened.json` in the data directory (path → count, top 500), written by the
service, so the app and `quoll find --sort opened` agree. The engine resolves the
paths to ids once per query into a sorted raw buffer; the comparator binary-
searches it (no dictionary access in the hot path, D7).
