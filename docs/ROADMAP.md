# Roadmap

## 1.0 (current)

- [x] Recursive scanner with excludes and symlink policy.
- [x] JSON catalog with atomic persistence.
- [x] Boolean query parser, filters, wildcards and regex.
- [x] Sort keys and result paging.
- [x] FSEvents live updates with debounce.
- [x] Unix-socket control server and CLI client.
- [x] Optional HTTP server with Basic auth.
- [x] JSON / CSV / TSV export.
- [x] Menu-bar app bundle.
- [x] Self-test runner.

## 1.1

- [ ] `getattrlistbulk` scanner for large volumes.
- [ ] Incremental catalog journal instead of full rewrites.
- [ ] Memory-mapped name table with prefix buckets.
- [ ] Multi-threaded matching for large result sets.
- [ ] Saved queries and per-query filters in the app.
- [ ] Drag-and-drop paths into the search field.
- [ ] Launch-at-login installer polish.

## 1.2

- [ ] Content search (`body:`) through Spotlight or a bounded text scanner.
- [ ] Duplicate detection (`same:name`, `same:bytes`, `same:content`).
- [ ] Saved file lists as read-only catalog sources.
- [ ] CSV import/export of saved lists.
- [ ] Remote source: query another Quoll instance over HTTP.
- [ ] Plugin protocol for custom filters.

## 2.0

- [ ] Shared team catalogs with ACLs.
- [ ] Query subscriptions and change notifications.
- [ ] Linux port of the core library.
- [ ] Stable file-format specification and migration tool.

## Non-goals

- Reading foreign search databases.
- Loading native plugins from other operating systems.
- Emulating other applications' control surfaces.
- Indexing file contents by default.
