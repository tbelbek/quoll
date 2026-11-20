# Architecture

Quoll is a per-user file search service with three front-ends:

```
                 ┌──────────────────────────────┐
  quoll CLI ────▶│                              │
  menu-bar app ─▶│        QuollService          │
  HTTP clients ─▶│                              │
                 └───────┬──────────┬───────────┘
                         │          │
                 ┌───────▼───┐  ┌───▼────────────┐
                 │  Catalog  │  │  ChangeWatcher │
                 └───────┬───┘  └───┬────────────┘
                         │          │
                 ┌───────▼──────────▼───────────┐
                 │  Scanner (FileManager walk)  │
                 └──────────────────────────────┘
```

## Components

### `Scanner`

Walks one or more roots with `FileManager.enumerator`, collecting `FileEntry`
values: path, name, kind, byte size, timestamps, extension, depth and mount.
The scanner handles excludes, hidden files, package descendants and symlinks.
It returns `ScanResult` with entries, `ScanIssue` rows and a duration.

### `Catalog`

Thread-safe, path-keyed collection of `FileEntry` values plus roots and the
last scan date. It persists to `catalog.json` with an atomic write. The catalog
is deliberately disposable: a missing or corrupt file is a rebuild, not an
error.

Methods: `replaceAll`, `put`, `insert`, `remove`, `removeBranch`,
`allEntries`, `entry(at:)`, `save`, `load`.

### `ChangeWatcher`

Wraps an FSEvents stream for the active roots. Events are coalesced for a
short debounce window and delivered as one batch of paths. The service then
re-stats files and rescans changed directories.

### `QueryEngine` and `SearchParser`

`SearchParser` turns a query string into an expression tree of `Predicate`
values. `Matcher` evaluates the tree against a `FileEntry`. `QueryEngine`
filters the catalog, sorts the matches and applies offset/limit.

The evaluator is independent of the storage layer, so it can be unit-tested
with synthetic entries.

### `ControlServer` / `ControlClient`

A Unix-domain socket carrying one JSON object per line. It is the only local
API: the CLI and the menu-bar app both use it. The socket is created with mode
`0600` under the application-support directory.

### `WebServer`

Optional HTTP endpoint built on `Network.framework`. It serves `/search`,
`/status` and `/export`, plus static files from a configured root. Basic
authentication is enabled when a username is set.

### `QuollService`

Owns the catalog, scanner, watcher and servers. It serializes scan and update
work on a private queue, debounces catalog writes, and maps control requests
to operations. `serve` starts the service; `QuollApp` either connects to an
existing service or starts one in-process.

## Concurrency

- `Catalog` guards its dictionary with a lock; reads are snapshots.
- `QuollService` serializes scans and change batches on `stateQueue`.
- Catalog persistence is debounced by two seconds after a change batch.
- The control server handles each client on a concurrent queue; commands that
  mutate the catalog synchronize with `stateQueue`.

## Storage

`catalog.json`:

```json
{
  "version": 1,
  "roots": ["/Users/you"],
  "lastScan": "2026-11-20T09:00:00Z",
  "entries": [
    {
      "path": "/Users/you/Documents/report.pdf",
      "name": "report.pdf",
      "isDirectory": false,
      "size": 48210,
      "modified": "2026-11-19T18:04:00Z",
      "created": "2026-11-01T11:30:00Z",
      "accessed": "2026-11-19T18:04:00Z",
      "fileExtension": "pdf",
      "level": 4,
      "mount": "/"
    }
  ]
}
```

The format is intentionally simple and inspectable. A binary or memory-mapped
catalog is on the roadmap; the JSON file is the compatibility baseline.

## Failure behavior

- Unreadable paths are recorded as `ScanIssue` and skipped.
- A failed catalog write is logged; the in-memory catalog remains usable.
- A missing FSEvents root is ignored; scanning still works.
- A stale socket file is unlinked on startup.
- The HTTP server is opt-in and never starts unless `web.enabled` is true.
