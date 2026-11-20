# Query language

Quoll queries are a small boolean expression language with property filters.
Whitespace is AND; `|` is OR; `!` or a leading `-` is NOT; quotes group a
phrase; parentheses group expressions.

## Examples

```text
report
report draft
"quarterly report"
ending:pdf changed:today
kind:file bytes:>50mb
under:src ending:swift
starts:2026- ends:.csv
path:clients !path:archive
pattern:^v[0-9]+\.[0-9]+
```

## Operators

| Syntax | Meaning |
| --- | --- |
| `foo bar` | `foo` AND `bar` |
| `foo\|bar` | `foo` OR `bar` |
| `!foo`, `-foo` | NOT `foo` |
| `"foo bar"` | literal phrase |
| `(foo\|bar) baz` | grouping |
| `foo*`, `f?o` | wildcard (whole name) |

Operators are literal inside quotes. A term with `*` or `?` is treated as a
whole-name wildcard unless another mode is selected.

## Filters

### Kind and extension

| Filter | Example | Meaning |
| --- | --- | --- |
| `kind:` | `kind:file`, `kind:folder` | entry kind |
| `ending:` | `ending:swift`, `ending:.pdf`, `ending:jpg;png;heic` | file extension (one, or a `;`-separated list) |
| `leaf:` | `leaf:README` | match the name only |
| `fullpath:` | `fullpath:src` | match the full path |
| `path:` | `path:clients` | path contains |
| `under:` | `under:src`, `under:~/Projects` | inside a folder subtree (folder name anywhere, or absolute path) |
| `parent:` | `parent:src`, `parent:/tmp` | direct parent folder (name or absolute path) |
| `level:` | `level:>3` | path depth |

### Size

Sizes accept `b`, `k`, `kb`, `m`, `mb`, `g`, `gb`, `t`, `tb` (binary units).

```text
bytes:0
bytes:>1mb
bytes:<=500k
bytes:1kb..2mb
```

### Time

Dates accept `today`, `yesterday`, `YYYY`, `YYYY-MM`, `YYYY-MM-DD`,
comparisons (`<`, `<=`, `>`, `>=`) and ranges (`..`).

```text
changed:today
changed:<2024
changed:2024-01..2024-06
made:>=2025-01-01
touched:yesterday
```

`changed` is the modification time, `made` the creation time and `touched`
the access time.

### Name and text modes

| Filter | Meaning |
| --- | --- |
| `starts:` | name/path starts with the value |
| `ends:` | name/path ends with the value |
| `exact:` | exact name |
| `word:` | whole-word matching |
| `pattern:` | regular expression |
| `matchcase:` | case-sensitive matching |
| `icase:` | case-insensitive matching |
| `leafonly:` | match the name, not the path |
| `fullpath:` | match the full path |
| `anyword:` | turn `word:` off again |
| `blank:` | empty files |

Modifiers can be standalone (`matchcase: report`) or carry the term
(`matchcase:Report`).

## Scopes

`scope:name` expands to a saved query. Built in: `scope:user` = your own files
(`under:~ !under:~/Library !path:/. !path:.photoslibrary/`: no Library, no
dot-folders, no Photos library internals). Define more in Settings or
`settings.json` (`"scopes": {"work": "under:~/Repos ending:md"}`); they also appear
in the filter menu. Sort `--sort opened` puts the files you open most from Quoll
first.

## Warnings

Unknown filters are not silently ignored. The parser returns a warning such as
`unsupported filter 'body:'` alongside the result. This makes a typo visible
instead of turning it into a literal filename match.

## Matching rules

- Default matching is case- and diacritic-insensitive substring matching on the
  file name. Names are folded once at index time (NFD, marks stripped, lowercase,
  `ı` → `i`), so `istanbul` finds `İSTANBUL` and `irmak` finds `ırmak`; wildcards,
  `word:` and `path:` use the same folding.
- Wildcards match the whole name.
- `pattern:` uses ICU regular expressions and searches anywhere in the name
  unless the pattern anchors itself.
- `word:` requires a non-word character (or string boundary) on both sides.
- Filters are ANDed with the text term in the same token.
- A date names a period: `changed:2025` is the whole year, `changed:2025-06`
  the whole month, `changed:2025-06-30` that day. Comparisons use the period's
  bounds: `changed:>2025` is after 2025, `changed:<=2025-06` up to the end of June,
  `changed:2025-01..2025-03` January through March.
- `chars:<n>` filters by name length; `plain:` turns `pattern:` off again.
- On the command line, a query that starts with `-` needs `--` first:
  `quoll find -- -draft`.
