# Audit — `feature/notebooks-v1.1` vs `main`

**Audited:** 2026-05-23
**Branch tip:** `5ae9593` (May 7 2026) — single commit not on main: *v1.1: annotations panel overhaul + editor selection fix*
**Main tip at audit:** `2ee5185`
**Verdict:** **Feature-superseded by `main`.** Safe to `git branch -D` after this audit lands in the consolidation tag.

## Method

Same protocol as the carousel audit. Beyond `merge-base --is-ancestor` and `cherry`, a feature-level read for branch-only surfaces:

```sh
BR=feature/notebooks-v1.1
git diff --name-status main..$BR
git diff --stat        main..$BR
git cherry -v main $BR
git ls-tree -r --name-only $BR  | sort > /tmp/notebooks-files.txt
git ls-tree -r --name-only main | sort > /tmp/main-files.txt
comm -23 /tmp/notebooks-files.txt /tmp/main-files.txt   # files on branch only
```

Then manual `git grep` passes for types, funcs, UserDefaults/AppStorage keys, enum cases, sheet/overlay modifiers, tests.

## Findings

### Patch identity

```
$ git cherry -v main feature/notebooks-v1.1
+ 5ae959393165268c3404831f99d2bcc1b1c2d672 v1.1: annotations panel overhaul + editor selection fix
```

`+` prefix means git's patch-id check sees this commit as NOT patch-applied to main. The earlier "already in main as `a3a08ad`" framing was wrong — these are sibling commits with different patch-ids. Accurate framing: **feature-superseded**.

### Files

- **Branch-only files:** none.
- **Main-only files** (deleted on branch relative to main, ordered by category):
  - Carousel pipeline: `CarouselCleanTranscriptView.swift`, `CarouselCoordinator.swift`, `CarouselNoteFormatter.swift`, `CarouselOCRService.swift`, `CarouselPayload.swift`, `CarouselSlidesStripView.swift`, `InstagramCarouselExtractor.swift`, `TikTokPhotoExtractor.swift`
  - Export Templates: `ExportTemplatePrefs.swift`, `TemplateSettingsView.swift`
  - Share queue: `SharedURLQueue.swift`, `ReSerchShareExtension/ShareViewController.swift`
  - Notes & journal: `DataExportService.swift`, `DocumentNotesJournalSheet.swift`
  - iCloud: `iCloudSyncService.swift`
  - Analytics: `Analytics.swift`
  - Entitlements: `ReSerch.entitlements`, `ReSerchShareExtension/ReSerchShareExtension.entitlements`, `ReSerchShareExtension/Info.plist`
  - Tests + fixtures: `CarouselNoteFormatterTests.swift`, `InstagramCarouselExtractorTests.swift`, `TikTokPhotoExtractorTests.swift`, `PlainHighlightUpgradeTests.swift`, `ShareJobQueueTests.swift`, plus 5 Instagram/TikTok JSON fixtures under `ReSerchTests/Fixtures/`
  - Doc: `docs/codex-brief-durable-share-queue.md`

  None of these are at risk — they exist on main and the branch never had them. Going from main back to this branch would DELETE all of the above. That's how outdated this branch is.

### Size

```
54 files changed, 487 insertions(+), 8388 deletions(-)
```

Main has ~8K more functional lines than this branch. The branch predates most of the past month of shipped work.

### Branch-only symbols

- **Types:** none.
- **Top-level funcs:** one hit — `setDocumentNote`. Investigated below.
- **UserDefaults / AppStorage keys:** none.

#### `setDocumentNote` — schema evolution, not feature loss

```swift
// feature/notebooks-v1.1:ReSerch/TranscriptViewModel.swift:631
func setDocumentNote(_ entry: TranscriptEntry, to note: String) { ... }
```

This is the **old single-document-note-per-transcript API**. Main has replaced the single `documentNote: String?` field with a `documentNotes: [DocumentNote]` array of identifiable pinnable notes, and the API now reads:

```swift
// main:ReSerch/TranscriptViewModel.swift
func addDocumentNote(_ entry: TranscriptEntry, text: String = "") -> UUID?
func updateDocumentNote(_ entry: TranscriptEntry, noteID: UUID, text: String)
func removeDocumentNote(_ entry: TranscriptEntry, noteID: UUID)
func pinDocumentNote(_ entry: TranscriptEntry, noteID: UUID)
func unpinDocumentNote(_ entry: TranscriptEntry, noteID: UUID)
```

Strictly more capable. The notebooks-v1.1 surface (single note, set-or-overwrite) is a degenerate case of main's surface (one note in the array, no pin). No feature lost.

### Branch-only UI surfaces

Two hits, both the same pattern as carousel:

- `.sheet(isPresented: $showAnnotations)` — old modal annotations sheet, replaced by main's inline `sidePeekPanel`.
- `.sheet(isPresented: $showDocNoteEditor)` — old modal doc-note editor, replaced by main's inline panel + `sidePeekNoteCard` flow.

Both are intentional UX upgrades on main (avoids modal nesting + the "Done Done" double-toolbar bug). Functionally subsumed.

### Branch-only tests

None. (Main has many tests this branch lacks — see the Main-only files list above.)

## Conclusion

Zero branch-only surfaces survive feature-level audit:

- 0 branch-only files
- 0 branch-only types
- 1 branch-only func (`setDocumentNote`) — the old API for a feature main has reimplemented under a strictly more capable schema
- 0 branch-only UserDefaults/AppStorage keys
- 2 branch-only `.sheet` modifiers, both intentionally replaced by main's inline panel

Nothing functional on `feature/notebooks-v1.1` is missing from `main`. The branch is safe to delete.

**Action gated on this audit:** `git branch -D feature/notebooks-v1.1` in Stage 6.
