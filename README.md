# Quoll

Fast, local file search for macOS. Quoll keeps a warm catalog of your disks and
answers filename queries in milliseconds, with a menu-bar app, a CLI and a
small local service that other tools can query.

Measured on a MacBook Air, whole home folder (2.3M entries): full scan 11.7 s,
170 MB snapshot on disk, start-up 3.4 ms, service footprint ~4 MB idle and up to
~17 MB while searching, substring queries < 6 ms. Dot-folders are indexed
(Spotlight skips them). Details: [docs/DECISIONS.md](docs/DECISIONS.md).

macOS has Spotlight, but it is optimized for content and metadata search and
does not behave like a filename index you can query instantly, filter with a
boolean expression, or script over a stable local protocol. Quoll fills that
gap.

## Features

- Memory-mapped catalog with incremental FSEvents updates, including changes
  made while Quoll was not running.
- Default excludes (`.git`, `node_modules`, `.Trash`, `.cache`,
  `~/Library/Caches`, `~/Library/CloudStorage`); includes override them.
- Boolean queries, quoted phrases, wildcards, regex and property filters.
- Sort by name, path, size, timestamps, extension or depth.
- CLI (`quoll`), menu-bar app and JSON/CSV/TSV export.
- Local control socket with a line-oriented JSON protocol.
- Optional HTTP endpoint with Basic authentication.
- Per-user data, no network access required.

## Install

**Download.** Grab `Quoll-<version>-macos-universal.zip` from
[Releases](https://github.com/tbelbek/quoll/releases), unzip, move `Quoll.app` to
`/Applications`. Unless the release notes say it is notarized, macOS quarantines
apps from the internet; clear that once:

```bash
xattr -dr com.apple.quarantine /Applications/Quoll.app
```

**First launch.**

1. Open Quoll; a magnifier icon appears in the menu bar (on a notched MacBook it
   may hide behind the notch when the bar is full).
2. Grant **Full Disk Access** (System Settings › Privacy & Security › Full Disk
   Access › add Quoll), otherwise macOS asks folder by folder and the first scan
   waits for each answer.
3. Press the hotkey: **Hyper+S** (⌃⌥⇧⌘S) by default. With a tool that maps Caps Lock to ⌃⌥⌘ (a "super key", e.g. Vorssaint) use `super+s`. Change it in Settings (⌘,) or `quoll settings --hotkey super+s`,
   e.g. `control+option+space` or `cmd+shift+f`.

**Window.** Type to search; matches are shown in bold. ↑/↓ select, Enter opens,
⌘Enter reveals in Finder, ⌘Y Quick Look, ⌘C copies paths, ⌘⌥C names, Esc hides,
⌃⌘F full screen. Click a column header to sort; right-click the header to show
Created or Kind. Settings (⌘,) holds the hotkey, open at login, the folders to
index, excludes and includes. `quoll show` (or opening the app again) brings the
window up, handy over a remote session.

**Build from source** (Command Line Tools are enough):

```bash
./scripts/make-signing-identity.sh   # optional: keeps Full Disk Access across rebuilds
./scripts/build-app.sh               # .build/Quoll.app (host architecture)
./scripts/release.sh                 # dist/Quoll-<version>-macos-universal.zip
```

Tagging `v<VERSION>` runs `.github/workflows/release.yml`, which builds the
universal zip and publishes a GitHub release. With `DEVELOPER_ID_P12`,
`DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD`
secrets set, it signs with the Developer ID and notarizes.

## Requirements

- macOS 13 or newer.
- Swift toolchain with tools-version 5.9 or newer (Command Line Tools are enough).

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

The CLI also ships inside the app: `/Applications/Quoll.app/Contents/MacOS/quoll-cli` (link it into your PATH as `quoll`).

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
| `under:src`, `parent:docs`, `path:clients` | folder (name or absolute path) / path |
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
  Sources/QuollCore/   IndexStore, BulkScanner, watcher, query engine, control, web
  Sources/quoll/       CLI
  Sources/QuollApp/    Menu-bar app
  Sources/QuollSelfTest/
scripts/               App bundle and launchd helpers
```

## Data

All data lives under `~/Library/Application Support/Quoll`:

```
settings.json          roots, excludes, includes, web settings
index -> index-<n>/    current snapshot (memory-mapped column files)
quoll.sock             control socket (mode 0600)
```

Deleting the directory resets Quoll; the next start rescans. Excludes and
includes:

```bash
quoll settings --include ~/Library/Caches/com.example   # index one excluded folder
quoll settings --include node_modules                    # stop excluding a name
quoll settings --no-default-excludes                     # index everything
```

## Status

Roadmap milestones M0–M4 (benchmark, waste fixes, column store, search engine,
durable change tracking) are done; see [docs/ROADMAP.md](docs/ROADMAP.md).
Run the checks with `swift run -c release quoll-selftest`, plus
`--bench <root> [--queries]`, `--equiv <root>` and `--m4`.

## License

MIT. See [LICENSE](LICENSE).
