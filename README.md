# Quoll

Fast, local file search for macOS. Quoll keeps a warm catalog of your disks and
answers filename queries in milliseconds, with a menu-bar app, a CLI and a
small local service that other tools can query.

macOS has Spotlight, but it is optimized for content and metadata search and
does not behave like a filename index you can query instantly, filter with a
boolean expression, or script over a stable local protocol. Quoll fills that
gap.

## Features

- Warm filename catalog with incremental updates from FSEvents.
- Boolean queries, quoted phrases, wildcards, regex and property filters.
- Sort by name, path, size, timestamps, extension or depth.
- CLI (`quoll`), menu-bar app and JSON/CSV/TSV export.
- Local control socket with a line-oriented JSON protocol.
- Optional HTTP endpoint with Basic authentication.
- Per-user data, no network access required.

## Requirements

- macOS 13 or newer.
- Swift 6 toolchain (Command Line Tools are enough).

## Build

```bash
cd macos
swift build -c release
swift run quoll-selftest
```

## Quick start

```bash
# Scan the default roots (home and /Applications), or give explicit paths.
swift run quoll scan

# Search.
swift run quoll find 'ending:swift starts:Package'

# Inspect the catalog and service state.
swift run quoll status

# Run the background service and HTTP endpoint.
swift run quoll serve --http --port 8484
curl 'http://127.0.0.1:8484/search?q=ending:swift&json=1'
```

The menu-bar app:

```bash
./scripts/build-app.sh
open .build/Quoll.app
```

## Query language

| Syntax | Meaning |
| --- | --- |
| `foo bar` | both terms |
| `foo\|bar` | either term |
| `!foo`, `-foo` | exclude |
| `"foo bar"` | exact phrase |
| `ending:swift` | file extension |
| `kind:file`, `kind:folder` | entry kind |
| `bytes:>1mb`, `bytes:1kb..2mb` | size |
| `changed:today`, `made:2024-01..2024-06` | timestamps |
| `starts:Report`, `ends:.pdf` | name boundaries |
| `under:src`, `path:clients` | folder / path |
| `level:>2` | path depth |
| `blank:` | empty files |
| `pattern:^v[0-9]+` | regular expression |
| `matchcase:`, `icase:` | case sensitivity |
| `word:`, `anyword:` | whole-word matching |
| `fullpath:`, `leafonly:` | match full path or name |
| `exact:` | exact name |

Full reference: [docs/QUERY.md](docs/QUERY.md).

## Layout

```
docs/                  Architecture, query language, protocol, roadmap
macos/
  Sources/QuollCore/   Catalog, scanner, watcher, query engine, control, web
  Sources/quoll/       CLI
  Sources/QuollApp/    Menu-bar app
  Sources/QuollSelfTest/
scripts/               App bundle and launchd helpers
```

## Data

All data lives under `~/Library/Application Support/Quoll`:

```
settings.json          roots, excludes, web settings
catalog.json           file catalog
quoll.sock             control socket (mode 0600)
```

Deleting the directory resets Quoll; the next scan rebuilds the catalog.

## Status

The core is working end to end: scan, query, live updates, CLI, menu-bar app,
control socket and HTTP. See [docs/ROADMAP.md](docs/ROADMAP.md) for what is
next.

## License

MIT. See [LICENSE](LICENSE).
