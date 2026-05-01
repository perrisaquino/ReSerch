---
title: Carousel / Photo Analyzer
date: 2026-05-01
status: approved-design
target_branch: feature/notebooks-v1.1 (or successor)
---

# Carousel / Photo Analyzer

## Summary

Extend ReSerch to handle Instagram carousels and TikTok photo posts. User pastes a link (or uses the Share Extension); the app detects it is image-based content, downloads the slides, runs on-device OCR, and writes an Obsidian-formatted Markdown note in the same shape as existing video transcripts. No new UI surface in the main flow.

## Goals

- One paste box, one share extension. The user does not pick a mode.
- Output matches the existing transcript note conventions (creator, caption, metadata, link back to post).
- On-device, no new cloud dependency, no new third-party SDK.

## Non-Goals (v1)

- Mixed video+photo carousels (IG started supporting these). Detect and route to the existing video extractor for the first child; log a warning. v2 problem.
- OCR translation of non-English slides.
- Re-running OCR on existing notes.
- Background bulk carousel processing — reuse the existing bulk infra in a follow-up.

## Architecture

Fits the existing `PlatformRouter` + extractor pattern.

### New types

- `ContentKind` enum: `.video`, `.carousel`. Returned by router alongside the platform.
- `CarouselSlide` value type: `index: Int`, `imageURL: URL`, `localImagePath: URL?`, `recognizedText: String?`.
- `CarouselPayload`: ordered `[CarouselSlide]` + the same metadata struct already used by video extractors (creator handle, creator profile URL, post URL, caption, like count, slide count).

### New extractors

- `InstagramCarouselExtractor` — parses `GraphSidecar` / `edge_sidecar_to_children` from the IG page JSON, returns ordered image URLs. Detection signal: `__typename == "GraphSidecar"` or presence of `edge_sidecar_to_children.edges`.
- `TikTokPhotoExtractor` — parses TikTok photo-post JSON (`imagePost.images[].imageURL.urlList`). Detection signal: presence of `imagePost`, absence of `videoData`.

Both follow the same shape as `InstagramWebExtractor` / `VideoExtractor` so existing scraping helpers are reused.

### New services

- `CarouselOCRService`
  - Downloads images concurrently (bounded `TaskGroup`, max 4 in flight).
  - Runs `VNRecognizeTextRequest` per image: `recognitionLevel = .accurate`, `usesLanguageCorrection = true`, default observation order.
  - Per-slide timeout: 10s. On timeout, leave `recognizedText = nil`.
  - Writes images to the Obsidian attachments directory only if the "Embed images" setting is on. Reuse the path resolution that the existing thumbnail save code uses.
- `CarouselNoteFormatter`
  - Mirrors the existing transcript formatter.
  - Produces the Markdown note (format below).

### Router change

`PlatformRouter` gains a pre-download branch: after fetching the page HTML, decide `ContentKind`. Return `(platform, kind)`. Downstream coordinator dispatches to either the existing video pipeline or the new carousel pipeline.

## Note Format

```markdown
# [{creator_display_name}]({creator_profile_url}) — Carousel

> {caption}

**Creator:** [@{handle}]({creator_profile_url})
**Likes:** {like_count}
**Slides:** {n}
**Source:** [See post]({post_url})

---

## Slide 1
![[{filename}-01.jpg]]
{recognized text, or *[no text detected]*}

## Slide 2
![[{filename}-02.jpg]]
{recognized text}

...
```

Rules:
- Creator handle and "See post" are always Markdown links.
- The `![[...]]` image embed line is only emitted when "Embed carousel images" is on.
- An OCR-empty slide always renders the `## Slide N` heading; the text body is `*[no text detected]*`.
- File naming for images: `{post_slug}-{slide_index_zero_padded}.jpg`. Slug derives from existing post-slug logic used for thumbnails.

## Settings

One new toggle in the existing settings screen:

- **Embed carousel images in notes** (Bool, default `true`).
  - Persisted via the same mechanism as the other toggles (`@AppStorage` or whatever the existing settings use — to be matched, not invented).

## UX

- Paste box: unchanged.
- Share extension: unchanged.
- Progress indicator label switches to "Extracting slide {i} of {n}…" when `ContentKind == .carousel`.
- History list: carousel notes appear with a small carousel icon next to the existing video icon (use SF Symbol `square.stack` or equivalent already in the asset catalog if present).

## Edge Cases

- **Mixed video+photo sidecar (IG):** route to existing video extractor for the first video child, log a warning, surface a non-blocking toast: "Mixed carousel — only the first video was transcribed." Defer full handling to v2.
- **Slide image fails to download:** skip image, render slide heading + `*[image unavailable]*`. Do not abort the whole note.
- **OCR per-slide timeout (10s):** leave text nil, still render the slide. Image (if toggle on) is unaffected.
- **Empty carousel (zero children):** treat as scrape failure, surface the existing scrape-failure error.
- **Carousel with > 20 slides:** no special handling. IG/TikTok cap at 10/35 respectively; if the cap moves, we still iterate.
- **Non-English text:** Vision auto-detects supported languages. No translation. Recognized text is saved as-is.

## Testing

- Unit tests:
  - `InstagramCarouselExtractor` — fixture HTML for: standard sidecar, mixed video+photo sidecar, single-photo (not a carousel).
  - `TikTokPhotoExtractor` — fixture JSON for: photo post, video post (must not match), photo post with one image.
  - `CarouselNoteFormatter` — golden-file Markdown for: all-text-slides, all-empty-slides, mixed, embed-images on/off.
- Integration tests (one per platform, network-required, marked accordingly):
  - One known-public IG carousel URL.
  - One known-public TikTok photo-post URL.
  - Both assert: note is produced, slide count matches, links are clickable Markdown.

## Build Sequence

1. Add `ContentKind` enum and update `PlatformRouter` to return `(platform, kind)`. No behavior change yet — `kind` is always `.video`.
2. Add `CarouselSlide` / `CarouselPayload` types.
3. `InstagramCarouselExtractor` + parser unit tests.
4. `TikTokPhotoExtractor` + parser unit tests.
5. `CarouselOCRService` (download + Vision) with mock-image unit test.
6. `CarouselNoteFormatter` + golden-file tests.
7. Settings toggle.
8. Wire the carousel branch into the post-router coordinator.
9. Progress indicator label change.
10. History list icon.
11. Integration tests.

## Open Questions

None blocking. Image-ordering tuning (Vision observation sort) deferred until real captures show a problem.
