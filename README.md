# Quoll

**Instant filename search for macOS, in the spirit of Everything.** Press a
hotkey, type, and every file and folder in your home folder is there in a few
milliseconds — including the dot-folders Spotlight never indexes.

| Whole home folder, MacBook Air | |
| --- | --- |
| Entries | 2.3 million |
| Full scan | 11.7 s (once; afterwards updates are incremental) |
| Start-up | 3.4 ms (memory-mapped index) |
| Memory while idle / searching | ~4 MB / up to ~17 MB |
| Typical query | 2–10 ms |
| Index on disk | 170 MB |

Spotlight is built for content and metadata, skips every path under a
dot-folder (`.config`, `.git`, `.raw`, …) and cannot be queried like an index.
Quoll keeps its own filename index, updates it from FSEvents, and answers from a
menu-bar app, a command-line tool, a local socket and an optional HTTP endpoint.
Everything stays on your Mac.

## Features

**Search**
- Search as you type over the whole index; matches shown in bold.
- Words, phrases, `|` (or), `!` (not), wildcards (`*.pdf`), regular expressions.
- Filters for extension (`ending:jpg;png;heic`), kind, size, modified/created
  dates (`changed:2025` is the whole year), folder (`under:`, `parent:`), path,
  depth, empty files, case and whole words.
- Case- and accent-insensitive by default, Turkish `ı/İ` included (`irmak`
  finds `ırmak`).
- Scopes: `scope:user` (your own files) built in, your own in Settings.

**Window**
- One global hotkey shows and hides it from anywhere; Esc hides.
- Columns: Name, Folder, Size, Modified, Opened, plus Created and Kind (header
  right-click). Sort by any of Name, Size, Modified, Created, Opened.
- Folders show their total size, computed from the index.
- Type filters (All, Folders, Documents, Pictures, Audio, Video, Archives, Code,
  My Files) and your scopes, ⌘1–⌘9.
- Recent and saved searches in the magnifier menu.
- Quick Look, Open With, Reveal in Finder, Open in Terminal, Rename, Move to
  Trash, copy paths or names, drag files out.
- "Opened" counts what you opened from Quoll; sort by it for most-used first.
- Index statistics: largest folders, file types by size.
- Movable, resizable, full screen; follows light and dark mode.

**Index**
- Incremental: live FSEvents updates (~1 s), and changes made while Quoll was
  not running are replayed at start (10k offline changes in ~1.5 s).
- Sensible default excludes (`.git`, `node_modules`, `.Trash`, `.cache`,
  `~/Library/Caches`, `~/Library/CloudStorage`); includes override any exclude;
  exclude a folder straight from a result. Rule changes apply without a rescan
  where possible.
- External drives (optional): a separate index per drive while it is connected,
  never blocking an eject, caught up on reattach.
- Full scans run in a short-lived helper process, so the app's memory stays small.
- Never downloads iCloud or File Provider content while scanning.

**Integrations**
- `quoll` CLI with `--paths` / `--json` output for scripts.
- Finder › Services › *Search in Quoll* (search inside a folder).
- `quoll://search?q=…` URLs and `quoll show "query"`.
- Local Unix socket with a line-oriented JSON protocol; optional HTTP endpoint.
- Open at login.

## Install

**Homebrew**

```bash
brew trust tbelbek/quoll                  # newer Homebrew asks before using a third-party tap
brew install --cask tbelbek/quoll/quoll   # Quoll.app in /Applications, `quoll` on PATH
```

**Download** `Quoll-<version>-macos-universal.zip` from
[Releases](https://github.com/tbelbek/quoll/releases) (Apple silicon and Intel),
unzip and move `Quoll.app` to `/Applications`. Releases are not notarized yet;
clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Quoll.app
```

**First launch**

1. Open Quoll. It lives in the menu bar (no Dock icon). On a notched MacBook with
   a crowded menu bar the icon can sit behind the notch; ⌘-drag it elsewhere, or
   use the hotkey / `quoll show`.
2. Grant **Full Disk Access** (System Settings › Privacy & Security › Full Disk
   Access › add Quoll). Without it macOS asks folder by folder and the first scan
   waits for each answer.
3. Press the hotkey — **Hyper+S** (⌃⌥⇧⌘S) by default. If Caps Lock is mapped to
   ⌃⌥⌘ (a "super key"), use `super+s`. Change it in Settings (⌘,) with the
   recorder, or `quoll settings --hotkey super+s`.
4. Optional: Settings › *Open Quoll at login*, *Index external drives*.

## Keyboard

| Key | Action |
| --- | --- |
| Hotkey | show / hide the window |
| Esc | hide |
| ↑ ↓, PgUp PgDn, ⌘↑ ⌘↓ | move the selection (focus stays in the search field) |
| Enter, double-click | open |
| ⌘Enter | reveal in Finder |
| ⌘Y | Quick Look |
| ⌘C / ⌘⌥C | copy paths / names |
| ⌘1 … ⌘9 | type filters (⌘9: My Files) |
| ⌘S | save the current search |
| ⌘L | back to the search field |
| ⌘R | reindex |
| ⌘I | index statistics |
| ⌘, | settings |
| ⌃⌘F | full screen |

## Query language

| Syntax | Meaning |
| --- | --- |
| `foo bar` | both words |
| `foo\|bar` | either word |
| `!foo`, `-foo` | without |
| `"foo bar"` | exact phrase |
| `*.pdf`, `report?.md` | wildcards over the whole name |
| `ending:md`, `ending:jpg;png;heic` | extension, or any of a list |
| `kind:file`, `kind:folder` | entry kind |
| `bytes:>1mb`, `bytes:1kb..2mb` | size |
| `changed:today`, `changed:2025`, `changed:>=2026-11-01`, `made:2025-01..2025-06` | modified / created; a year or month is the whole period |
| `starts:Report`, `ends:.pdf`, `exact:package.json` | name boundaries |
| `under:~/Projects`, `under:src` | inside an absolute folder / any folder with that name |
| `parent:docs` | direct parent folder |
| `path:clients/acme`, `fullpath:src/main` | full path contains / full-path text |
| `level:>3`, `blank:`, `chars:>40` | depth, empty files, name length |
| `pattern:^v[0-9]+`, `word:test`, `matchcase:README` | regex, whole word, case-sensitive |
| `scope:user`, `scope:<name>` | saved query |

`scope:user` = `under:~ !under:~/Library !path:/. !path:.photoslibrary/` (your own
files). Define more in Settings or in `settings.json`:
`"scopes": {"work": "under:~/Repos ending:md"}`.

Full reference: [docs/QUERY.md](docs/QUERY.md).

## Command line

The CLI ships inside the app (`/Applications/Quoll.app/Contents/MacOS/quoll-cli`;
Homebrew links it as `quoll`). It asks the running app over its socket, or maps
the last index read-only when the app is closed.

```bash
quoll find --paths --limit 20 'invoice ending:pdf'                       # one path per line
quoll find --json --limit 40 --sort modified --descending -- 'scope:user kind:file'
quoll find --paths --sort opened -- 'scope:user'                          # most opened first
quoll show 'under:~/Downloads changed:today'                              # open the window
quoll status
quoll settings --exclude ~/Downloads/old --include node_modules
quoll settings --hotkey super+s --open-at-login on --external-drives on
quoll scan ~/Projects ~/Documents                                         # change roots and rescan
quoll export 'ending:pdf' --format csv --output pdfs.csv
```

`--json` returns `{query, count, total, tookMS, truncated, warnings, results:
[{path, name, isDirectory, size, modified, created, accessed, fileExtension,
level, mount, openCount?}]}`; unknown filters are reported in `warnings`. A query
starting with `-` needs `--` before it. Socket and HTTP: [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Settings and data

Everything lives in `~/Library/Application Support/Quoll`:

```
settings.json      roots, excludes, includes, scopes, hotkey, openAtLogin,
                   indexExternalVolumes, useDefaultExcludes, http
index -> index-n/  current index (memory-mapped column files)
volumes/<uuid>/    indexes of external drives
opened.json        open counts (top 500)
quoll.sock         control socket (mode 0600)
```

Quoll reads file names and metadata only, never file contents, and makes no
network connections (the optional HTTP endpoint is off by default). Deleting the
folder resets Quoll; the next start rescans.

## Build from source

Command Line Tools are enough (no Xcode).

```bash
./scripts/make-signing-identity.sh   # optional: a local signing identity keeps Full Disk Access across rebuilds
./scripts/build-app.sh               # .build/Quoll.app for this Mac
./scripts/release.sh                 # dist/Quoll-<version>-macos-universal.zip
```

Tests and benchmarks:

```bash
cd macos
swift run -c release quoll-selftest                            # unit checks
swift run -c release quoll-selftest --bench ~ --queries        # scan, load and query timings
swift run -c release quoll-selftest --equiv ~/Projects         # new engine vs. reference matcher
swift run -c release quoll-selftest --m4                       # FSEvents replay and live updates
swift run -c release quoll-selftest --volumes <writable.dmg>   # external-drive index
```

Pushing a `v<VERSION>` tag builds the universal zip and publishes a GitHub
release (`.github/workflows/release.yml`). With `DEVELOPER_ID_P12`,
`DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_APP_PASSWORD` it signs with a Developer ID and notarizes; with `TAP_TOKEN`
it updates the Homebrew tap.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — index layout, scanner, change tracking, search engine
- [docs/DECISIONS.md](docs/DECISIONS.md) — every measured design decision
- [docs/QUERY.md](docs/QUERY.md) — query language
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — socket and HTTP
- [docs/ROADMAP.md](docs/ROADMAP.md) — what is done and what is next

## Requirements

macOS 13 or newer; Apple silicon or Intel.

## License

MIT. See [LICENSE](LICENSE).
