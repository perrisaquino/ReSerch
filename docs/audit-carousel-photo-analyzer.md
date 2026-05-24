# Audit — `feature/carousel-photo-analyzer` vs `main`

**Audited:** 2026-05-23
**Branch tip:** `f3d8010` (May 7 2026) — single commit: *Export templates + side-peek annotations editing*
**Main tip at audit:** `2ee5185`
**Verdict:** **Feature-superseded by `main`.** Safe to `git branch -D` after this audit lands in the consolidation tag.

## Method

Per the consolidation plan, this audit goes beyond `git merge-base --is-ancestor` (which only proves ancestry) and `git cherry -v` (which proves patch identity) to a feature-level read for branch-only surfaces.

Commands run:

```sh
BR=feature/carousel-photo-analyzer
git diff --name-status main..$BR
git diff --stat        main..$BR
git cherry -v main $BR
git ls-tree -r --name-only $BR  | sort > /tmp/branch-files.txt
git ls-tree -r --name-only main | sort > /tmp/main-files.txt
comm -23 /tmp/branch-files.txt /tmp/main-files.txt   # files on branch only
comm -13 /tmp/branch-files.txt /tmp/main-files.txt   # files on main only
```

Then manual `git grep` passes against both branches for: type declarations, top-level funcs, UserDefaults/AppStorage keys, enum cases, `.sheet`/`.fullScreenCover`/`.alert`/`.confirmationDialog`/`.popover` modifiers, and tests.

## Findings

### Patch identity

```
$ git cherry -v main feature/carousel-photo-analyzer
+ f3d80107905ca963c7b147a20d9660f068a69455 Export templates + side-peek annotations editing
```

`+` prefix means git's patch-id check sees this commit as NOT patch-applied to main. The content-similar commit `3c82b33` on main has a different patch-id (likely because the surrounding code evolved post-`3c82b33`, perturbing the diff context). So the framing "already in main" was sloppy — accurate framing is **feature-superseded**, not patch-equivalent.

### Files

- **Branch-only files:** none. Every Swift file present on the branch is also present on main.
- **Main-only files (i.e. deleted on branch vs main):**
  - `ReSerch/Analytics.swift`
  - `ReSerchTests/PlainHighlightUpgradeTests.swift`
  - `ReSerchTests/ShareJobQueueTests.swift`
  - `docs/codex-brief-durable-share-queue.md`

  These exist on main and not on the branch because the branch predates the analytics + plain-highlight-upgrade + share-queue work that landed on main between May 7 and May 19. No branch-side feature is at risk.

### Size

```
26 files changed, 471 insertions(+), 3067 deletions(-)
```

Going from `main` to the branch deletes ~3K lines net. Main strictly has more functional surface than the branch.

### Branch-only symbols

- **Types (class/struct/enum/protocol/extension/actor):** none.
- **Top-level funcs:** none.
- **UserDefaults / AppStorage keys:** none.
- **Enum cases:** one heuristic hit — `case id, name, colorHex, createdAt, notebookDescription` (the `Notebook.CodingKeys`). Resolved as a **false positive**: the line differs because main's `CodingKeys` is a strict superset (`case id, name, colorHex, createdAt, updatedAt, manualOrder, notebookDescription`). Carousel has fewer fields, not unique fields.

### Branch-only UI surfaces

One hit: `.sheet(isPresented: $showAnnotations)` in `TranscriptDetailView.swift`.

Investigation: `$showAnnotations` is the carousel branch's first-pass annotation panel — a modal sheet. Main intentionally replaced this with an inline edge-sliding panel (`showDocNoteEditor` + `sidePeekPanel`), explicitly to avoid the "Done Done" double-toolbar bug noted in main's own code comments. This is a **deliberate UX upgrade on main, not a lost feature** — the panel is functionally the same surface, just rendered above the NavigationStack instead of as a modal child.

### Branch-only tests

None. (Main has two test files — `PlainHighlightUpgradeTests.swift`, `ShareJobQueueTests.swift` — that the branch lacks.)

## Conclusion

Zero branch-only surfaces survive feature-level audit:

- 0 branch-only files
- 0 branch-only types
- 0 branch-only funcs
- 0 branch-only UserDefaults/AppStorage keys
- 0 real branch-only enum cases (1 false positive resolved)
- 1 branch-only `.sheet` modifier, intentionally replaced by main's inline panel

Nothing functional on `feature/carousel-photo-analyzer` is missing from `main`. The branch is safe to delete after this audit lands in the consolidation tag.

**Action gated on this audit:** `git branch -D feature/carousel-photo-analyzer` in Stage 6.
