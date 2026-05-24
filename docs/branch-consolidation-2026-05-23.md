# Branch Consolidation — 2026-05-23

This document explains what landed on `main` during the 2026-05-23 consolidation session and why. It's committed alongside two per-branch audit docs (`audit-carousel-photo-analyzer.md`, `audit-notebooks-v1.1.md`) and the whole set is captured under the tag `consolidation-2026-05-23` so the tagged state contains its own explanation.

## Quick facts

| Field | Value |
|---|---|
| Consolidation performed on | 2026-05-23 |
| Audit + doc committed on | 2026-05-23 |
| Reviewed merge tip before documentation | `2ee5185` |
| Consolidation documentation commit | see `git log -1 docs/branch-consolidation-2026-05-23.md` (self-referential SHA omitted; the tag below pins the canonical commit) |
| Tag | `consolidation-2026-05-23` |
| Smoke test | Passed on simulator (all 7 manual checks) |
| Codex review | Ran; no blockers |

## Why this happened

The repo had drifted into six-plus branches with overlapping work and unclear ownership. Before cutting a new TestFlight build, `main` needed to become the single, obvious source of truth and the loose branches needed to either land or be declared superseded.

## Branches collapsed (and how)

### Merged into main via no-ff merge commits

- **`feature/share-progress-and-notebook-sort`** — merged via `b0ad088` (no-ff). Carried `df93f99` (sidepeek durable comment save + commentable plain highlights + multi-line footnotes) and `8392351` (in-flight share jobs in feed + notebook sort + drag-reorder). An older icon commit (`29d8f9d`) was overridden during conflict resolution in favor of the new centered icon.
- **`fix/tiktok-recovery-misattribution`** — merged via `2ee5185` (no-ff, no conflicts). Carried `3810a71` (stop offering Instagram sign-in for failed TikTok URLs).

### Effectively already merged (work content present on main)

- **`fix/sidepeek-comment-save-and-add`** — its tip is the same change content as `df93f99`, which arrived on main through the `feature/share-progress-and-notebook-sort` merge. Nothing new to merge.
- **`feature/side-peek-tap-to-annotate`** — 0 commits ahead of main at audit time.

### Declared feature-superseded after audit (not merged, no work lost)

- **`feature/carousel-photo-analyzer`** — see `audit-carousel-photo-analyzer.md`. Single commit `f3d8010`. `git cherry -v` shows `+` (not patch-applied to main) but feature-level audit finds zero branch-only surfaces: 0 files, 0 types, 0 funcs, 0 UserDefaults keys, 0 real enum cases, 1 modal-`.sheet` UI surface that main intentionally replaced with an inline edge-sliding panel.
- **`feature/notebooks-v1.1`** — see `audit-notebooks-v1.1.md`. Single commit `5ae9593`. Similar pattern. The one branch-only func (`setDocumentNote`) is the old single-document-note-per-transcript API; main has replaced it with a multi-note schema (`addDocumentNote`/`updateDocumentNote`/`removeDocumentNote`/`pinDocumentNote`/`unpinDocumentNote`) backed by `documentNotes: [DocumentNote]`. Schema evolution, not lost feature.

### Backup branches retained through next TestFlight cycle

- `backup/main-pre-carousel-rebase-2026-05-23`
- `backup/carousel-pre-rebase-2026-05-23`

## Known nuance — "redundant" means *feature-superseded*

`git merge-base --is-ancestor` only proves ancestry; `git cherry -v` proves patch identity. Both feature/carousel-photo-analyzer and feature/notebooks-v1.1 show `+` in `git cherry -v` — meaning their commits are *not* literal patch-identical ancestors of main. The earlier "already in main" framing was sloppy. The accurate framing, used throughout this consolidation and the per-branch audits, is **feature-superseded**: every functional surface on the branch is present on main, in the same or strictly more capable form.

## App icon decision

White magnifier on near-black `(20, 20, 27)` background. 1024×1024, opaque, no alpha, no pre-rounded corners (iOS applies its own mask). Source: `IMG_8280 2.PNG`. Centering: artwork bbox shifted to canvas center (offset was only `dx=+1, dy=+7` from the source image). Used in all three `AppIcon.appiconset` appearance slots (light / dark / tinted) via a single PNG.

History during the session: a first purple-glow variant landed on main as `0d64144`; the final white-magnifier variant replaced it at `d0dd379`.

## ShareJobQueue chosen over `SharedURLQueue.enqueue`

The share extension's `handleIncomingShare()` now writes through `ShareJobQueue.shared.enqueue(...)`, which returns one of `.added` / `.duplicate` / `.full` / `.unavailable`. Each case maps to distinct user feedback (queued / queued / "Queue full. Open ReSerch to clear it." / deeplink fallback). The previous `SharedURLQueue.enqueue(...)` returned a single bool — any non-success path collapsed to deeplink, which surprised users when the queue was full because the app would suddenly foreground itself. The new switch is strictly safer and more informative.

## Conflict-resolution spot-check (Stage 2)

The blanket `git checkout --ours` decision during the aborted carousel rebase covered 28 hunks in `TranscriptDetailView.swift` and 6 hunks in `ShareViewController.swift`. Per the consolidation plan, five hunks were re-audited at the feature-area level to verify no UX was silently dropped:

| # | File / region | Why main wins |
|---|---|---|
| 1 | `ShareViewController.swift` — `handleIncomingShare` body | `ShareJobQueue.shared.enqueue(...)` 4-case switch vs carousel's single-bool. Main is strictly safer. |
| 2 | `ShareViewController.swift` — `firstSharedURL()` | Main extracts URLs from `item.attributedTitle?.string` AND `attributedContentText?.string`; carousel only the latter. Better coverage for share sources that put URLs in titles. |
| 3 | `TranscriptDetailView.swift` L71 — state vars | Main has `@State private var showMoveToNotebook` + `showNotebookDetail`. Carousel predates the move-to-notebook flow entirely. No lost UX; new feature on main. |
| 4 | `TranscriptDetailView.swift` L921 — `editorParsedHighlights` | Main's tuple carries `index: String` so `ForEach(..., id: \.index)` disambiguates when the same highlight text appears in multiple footnote refs. Also uses extracted multi-line-aware `parseFootnoteDefinitions`. Carousel had `id: \.text` (collides on dupes) and inline single-line footnote parsing. |
| 5 | `TranscriptDetailView.swift` L1544 — plain-highlight upgrade module | Main: 8 functions (`upgradePlainHighlight`, `applyPlainHighlightUpgrade`, `nextFootnoteIndex`, `serializeFootnote`, `parseFootnoteDefinitions`, `parseFootnoteHeader`, `writeFootnoteDefinition`, `saveMarkdownHighlightComment`) plus the `PlainHighlightUpgradeTests.swift` test suite. Carousel: 1 function, single-line only, no upgrade flow. |

Verdict: bulk `--ours` was the correct call. Zero UX lost across all five spot-checks. Main is strictly more capable in every region examined.

## Build + smoke test (Stage 3)

- Working tree clean before commit (only the audit docs untracked).
- No orphan conflict markers in any tracked Swift/Obj-C/header file.
- `xcodebuild -project ReSerch.xcodeproj -scheme ReSerch -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**.
- Manual simulator smoke test: all 7 checks passed (icon, feed, share progress, notebooks, sidepeek highlight upgrade + force-quit persistence, export templates, tiktok fix).

## Pointers

- Per-branch audit: [`audit-carousel-photo-analyzer.md`](audit-carousel-photo-analyzer.md)
- Per-branch audit: [`audit-notebooks-v1.1.md`](audit-notebooks-v1.1.md)
- Go-forward branch hygiene policy: `CONTRIBUTING.md` (added in a separate follow-up commit after this tag)
