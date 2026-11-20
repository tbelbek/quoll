# Architecture

Quoll is a per-user filename index with three front-ends (CLI, menu-bar app,
optional HTTP) talking to one service over a Unix socket. The design goal is the
smallest footprint that still answers any query in milliseconds; the measured
decisions behind it are in [DECISIONS.md](DECISIONS.md).

```
  quoll CLI ────┐
  menu-bar app ─┼──▶ QuollService ──▶ QueryEngine ──▶ IndexStore (read lock)
  HTTP clients ─┘         │                               ▲
                          │ FSEvents batches               │ write lock
                          ▼                               │
                    ChangeWatcher ── reconcile (lstat) ───┘
                          │
                    full scan ──▶ scan helper process ──▶ BulkScanner ──▶ snapshot files
```

## Storage: `IndexStore`

A catalog is a **snapshot** (files on disk, mapped read-only) plus a small
in-memory **overlay** of changes since the snapshot was written.

Snapshot generation `<data>/index-<n>/`, pointed at by the `<data>/index`
symlink (swapped atomically):

| File | Content |
| --- | --- |
| `folded.bin` / `folded.off` | folded names (NUL-terminated) and u32 start offsets |
| `raw.bin` / `raw.off` | display names, same layout |
| `parent.u32` | parent id (`UInt32.max` for roots) |
| `mtime.u32`, `ctime.u32` | modification / creation time, seconds |
| `size.u64` | logical size (0 for folders) |
| `flags.u8` | folder, symlink |
| `dirs.bin`, `dirs.inode` | per folder: child range + inode; permutation by inode |
| `meta.json` | roots, FSEvents event id, volume UUIDs, rules fingerprint |

Invariants: roots are ids `0..<roots.count`; a folder's children are one
contiguous id range sorted by (folded, raw) name; parents precede children.
Path lookup is therefore a binary search per path component.

Mapped pages are clean and file-backed: they do not count toward the process
footprint and the kernel drops them under memory pressure instead of swapping.

The overlay holds appended entries, a tombstone bitset, and per base entry
overrides for metadata, name and parent. A folder rename or move rewrites one
entry; its subtree is untouched. Compaction writes the live tree breadth-first
as a new snapshot (streamed to disk, ~0.4 s per million entries) and drops the
overlay.

## Names: `Fold`

Case-insensitive matching uses a folded copy of every name: NFD, strip combining
marks, lowercase, `ı` → `i` (locale-independent, so `İ I ı i` all match). ASCII
names, the common case, take a byte fast path.

## Scanning: `BulkScanner`

`getattrlistbulk` returns name, type, times, flags, inode and size for a whole
buffer of entries per syscall. Four workers share a folder stack; each reads one
folder, sorts it, then appends it to the snapshot writer under one lock, so a
folder's children land contiguously. Excluded folders are never opened; paths
are only built when a path rule could match below the folder. Dataless
(iCloud/File Provider) folders are skipped and materialisation is turned off for
the process. A walk stays on the root's device and never follows symlinks.

A **full scan** (first run, changed roots/rules/volume, FSEvents gap) runs in a
child process (`--quoll-scan-helper`), so the scan's malloc churn never stays in
the long-running service.

## Change tracking: `ChangeWatcher` + reconciliation

The FSEvents stream starts at the snapshot's event id, so everything that changed
while Quoll was not running is replayed first (`HistoryDone` marks the end).
Event flags are not trusted (they coalesce). Per batch, paths are deduplicated
and handled parents first; each is `lstat`-ed:

- missing → deferred removal (end of batch), so a moved folder can be claimed
- exists, indexed → metadata update; real on-disk name re-read (case renames)
- exists, not indexed, folder whose inode is already known → move/rename
- exists, not indexed → append; a new folder is walked into the overlay

`MustScanSubDirs` rescans that folder; dropped events, wrapped ids or a moved
root trigger a full scan. Quoll's own writes are ignored (`IgnoreSelf`) and its
data directory is always excluded.

## Search: `QueryEngine`

`SearchParser` (unchanged since 1.0) produces an expression tree. The plan
flattens it into reference-free buffers, because ARC traffic on shared objects
dominated per-entry evaluation. Every term contributes a literal its folded name
must contain; the longest one in the root (or a root AND) drives `memmem` over
the name arena, and only hits are evaluated. Work is split into 32k-entry chunks
across cores; each chunk keeps a bounded top-K heap. A newer interactive search
cancels an older one.

`under:` / `parent:` take a folder name or an absolute path; `path:` and
`fullpath:` rebuild paths for candidates only.

## Service: `QuollService`

Owns the store, engine, watcher, control socket and optional HTTP server. All
mutations run on one serial state queue under the store's write lock; queries
take the read lock. Compaction runs on shutdown, at 20,000 pending changes, or
when idle for 5 minutes once the snapshot is 6 hours old.

## Failure behaviour

- Unreadable folders are counted and skipped.
- A snapshot that does not match roots, rules or volumes is rescanned.
- A failed snapshot write keeps the previous generation.
- A stale socket file is unlinked on startup.
- The HTTP server never starts unless `http.enabled` is true.
