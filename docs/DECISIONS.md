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
