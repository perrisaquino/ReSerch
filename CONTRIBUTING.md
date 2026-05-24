# Contributing to ReSerch

## Branch hygiene

These rules came out of the 2026-05-23 consolidation (see `docs/branch-consolidation-2026-05-23.md`). Kept terse so they actually get followed.

1. **One feature per branch.** Name encodes intent: `feature/<thing>`, `fix/<bug>`, `chore/<housekeeping>`.

2. **Branch from latest `origin/main`.** Merge back within ~2 days, or rebase `main` into the branch daily if it has to live longer.

3. **Hot-spot files** — avoid long-running parallel branches that touch these, because every merge will conflict:
   - `ReSerch/TranscriptDetailView.swift`
   - `ReSerch/TranscriptViewModel.swift`
   - `ReSerch/AddTranscriptView.swift`
   - `ReSerchShareExtension/ShareViewController.swift`
   - `ReSerch.xcodeproj/project.pbxproj`
   - any `.entitlements`

4. **Never create a "v2" branch** for the same feature without closing or renaming the old one (e.g. `abandoned/<name>`). Two live branches for the same feature is how you lose work.

5. **Pre-merge ritual:**
   ```sh
   git status --short
   git log --oneline --decorate --graph -20
   git diff --stat main...feature/name
   git diff --name-only main...feature/name
   ```

6. **Post-resolution ritual** for any merge with conflicts: `git diff --check`, build (`xcodebuild ... build`), then commit.

7. **Conflict resolution on large SwiftUI files:** do not bulk `--ours`/`--theirs` without a follow-up feature-level audit comparing state vars, sheets, toolbar/bottom-bar actions, UserDefaults/AppStorage keys, helper functions, view-model calls, and tests between the two sides. Hunk-by-hunk reads during resolution are not enough.

8. **Redundancy claims** ("this branch is already merged") require feature-level audit, not just `git merge-base --is-ancestor`. Use the language **feature-superseded**, not "content-identical", unless `git cherry -v` returns `-` for every commit (patch-id proof) or you have explicit patch-identity. See `docs/audit-carousel-photo-analyzer.md` and `docs/audit-notebooks-v1.1.md` for the template.

## Consolidation tags

When collapsing multiple branches back to `main`, commit the explanation doc(s) **before** creating the tag, so the tag marks a state that contains its own explanation. Order: write doc → commit doc → push main → tag the now-published HEAD → push tag.

Verify with:

```sh
git ls-tree -r <tag> -- docs/<consolidation-doc>.md
```

Not `git show <tag> --stat`, which shows the diff rather than tree membership.

## Helper aliases (optional)

```sh
git config alias.lg "log --oneline --decorate --graph --all --max-count=40"
git config alias.incoming "log --oneline --decorate HEAD..@{u}"
git config alias.outgoing "log --oneline --decorate @{u}..HEAD"
git config alias.changed "diff --name-status"
```

User-scoped, reversible.
