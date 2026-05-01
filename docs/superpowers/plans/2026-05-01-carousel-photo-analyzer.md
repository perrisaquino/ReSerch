# Carousel / Photo Analyzer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Instagram carousel and TikTok photo-post support to ReSerch — paste a link, on-device OCR runs over each slide, output is an Obsidian-formatted Markdown note shaped like the existing transcript notes.

**Architecture:** Content kind (`.video` vs `.carousel`) is detected inside the per-platform extractors (not in `PlatformRouter`, which is URL-only and synchronous). New extractors return a `CarouselPayload`; a new `CarouselOCRService` runs `VNRecognizeTextRequest` per slide; a new `CarouselNoteFormatter` produces Markdown that lands in the existing `TranscriptResult.transcript` field, so detail view / history / export / notebooks keep working unchanged.

**Tech Stack:** Swift, SwiftUI, WKWebView (already used for IG scraping), Vision framework (`VNRecognizeTextRequest`), URLSession, XCTest.

---

## Spec Reference

Design spec: `docs/superpowers/specs/2026-05-01-carousel-photo-analyzer-design.md`

## Deviations from Spec

- **Router does NOT return `(platform, kind)`.** `PlatformRouter.detect(_:)` is synchronous and URL-only. Kind detection happens inside `InstagramWebExtractor` (extended) and a new `TikTokPhotoExtractor` once the page JSON is in hand.
- **No new `CarouselPayload` propagated downstream.** Carousel pipeline produces a `TranscriptResult` directly (transcript field = formatted slide Markdown, platform field carries `"Instagram (Carousel)"` / `"TikTok (Photos)"`). An internal `CarouselPayload` type is used only inside the carousel pipeline before formatting.

## File Structure

**Create:**
- `ReSerch/CarouselPayload.swift` — internal value types (`CarouselSlide`, `CarouselPayload`).
- `ReSerch/InstagramCarouselExtractor.swift` — detects sidecar in IG page JSON, returns `CarouselPayload`.
- `ReSerch/TikTokPhotoExtractor.swift` — detects photo post in TikTok page, returns `CarouselPayload`.
- `ReSerch/CarouselOCRService.swift` — concurrent download + Vision OCR per slide.
- `ReSerch/CarouselNoteFormatter.swift` — produces Markdown for `TranscriptResult.transcript`.
- `ReSerch/CarouselCoordinator.swift` — orchestrates: extract → OCR → format → produce `TranscriptResult`.
- `ReSerchTests/CarouselNoteFormatterTests.swift`
- `ReSerchTests/InstagramCarouselExtractorTests.swift`
- `ReSerchTests/TikTokPhotoExtractorTests.swift`
- `ReSerchTests/Fixtures/ig_sidecar.json`
- `ReSerchTests/Fixtures/ig_mixed_sidecar.json`
- `ReSerchTests/Fixtures/ig_single_photo.json`
- `ReSerchTests/Fixtures/tiktok_photo_post.json`
- `ReSerchTests/Fixtures/tiktok_video_post.json`

**Modify:**
- `ReSerch/InstagramWebExtractor.swift` — after page JSON loads, branch: if `__typename == "GraphSidecar"` (or `edge_sidecar_to_children` present), hand off to `InstagramCarouselExtractor` and return the result via a new result variant.
- `ReSerch/SettingsView.swift` — add `embedCarouselImages` `@AppStorage` toggle (default `true`).
- `ReSerch/AddTranscriptView.swift` (or wherever the URL paste flow dispatches to platform pipelines) — route IG/TikTok carousel results through `CarouselCoordinator`.
- `ReSerch/TranscriptViewModel.swift` — accept progress strings of the form `"Extracting slide {i} of {n}…"`.

---

## Task 1: Add `CarouselPayload` value types

**Files:**
- Create: `ReSerch/CarouselPayload.swift`
- Test: `ReSerchTests/CarouselNoteFormatterTests.swift` (created later — Task 5)

- [ ] **Step 1: Create the file**

```swift
import Foundation

struct CarouselSlide: Equatable {
    let index: Int               // zero-based
    let imageURL: URL
    var localImagePath: URL?     // set by OCR service if image embedding is on
    var recognizedText: String?  // nil = OCR failed/timed out, "" = ran but found nothing
    var imageDownloadFailed: Bool = false
}

struct CarouselPayload: Equatable {
    let platform: CarouselPlatform
    let postURL: URL
    let creatorHandle: String
    let creatorDisplayName: String
    let creatorProfileURL: URL
    let caption: String
    let likeCount: Int?
    let postedDate: Date?
    var slides: [CarouselSlide]

    var slideCount: Int { slides.count }
}

enum CarouselPlatform: String, Equatable {
    case instagram = "Instagram (Carousel)"
    case tiktok = "TikTok (Photos)"
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project ReSerch.xcodeproj -scheme ReSerch -destination 'generic/platform=iOS Simulator' build -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ReSerch/CarouselPayload.swift
git commit -m "Add CarouselSlide and CarouselPayload value types"
```

---

## Task 2: Settings toggle for image embedding

**Files:**
- Modify: `ReSerch/SettingsView.swift`

- [ ] **Step 1: Find the existing toggles section**

Run: `grep -n "AppStorage\|Toggle" ReSerch/SettingsView.swift | head -20`
Note the pattern other toggles use (likely `@AppStorage("someKey")` paired with `Toggle("Label", isOn: $binding)` inside a `Section`).

- [ ] **Step 2: Add the storage property at the top of `SettingsView`**

```swift
@AppStorage("embedCarouselImages") private var embedCarouselImages: Bool = true
```

- [ ] **Step 3: Add the toggle row in the most appropriate existing `Section`**

If a Section labelled "Output" / "Notes" / "Markdown" exists, place it there. Otherwise create a new `Section("Carousels")`:

```swift
Section("Carousels") {
    Toggle("Embed images in carousel notes", isOn: $embedCarouselImages)
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project ReSerch.xcodeproj -scheme ReSerch -destination 'generic/platform=iOS Simulator' build -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add ReSerch/SettingsView.swift
git commit -m "Add 'Embed images in carousel notes' setting (default on)"
```

---

## Task 3: Instagram carousel JSON parser

**Files:**
- Create: `ReSerch/InstagramCarouselExtractor.swift`
- Test: `ReSerchTests/InstagramCarouselExtractorTests.swift`
- Fixtures: `ReSerchTests/Fixtures/ig_sidecar.json`, `ig_mixed_sidecar.json`, `ig_single_photo.json`

This task only covers the pure JSON-to-CarouselPayload parsing function. WKWebView wiring lands in Task 7.

- [ ] **Step 1: Capture three real IG fixtures**

You need three JSON fixtures. The shape lives in IG's `media_info` API or the page's `__additionalDataLoaded` payload. Required fields per fixture:

`ig_sidecar.json` — a real `GraphSidecar` post with `edge_sidecar_to_children.edges[]`, each child having `display_url` (or `image_versions2.candidates[0].url`) and `__typename == "GraphImage"`. Also: `owner.username`, `owner.full_name`, `owner.id`, `edge_media_to_caption.edges[0].node.text`, `edge_media_preview_like.count`, `taken_at_timestamp`, `shortcode`.

`ig_mixed_sidecar.json` — same shape but at least one child has `__typename == "GraphVideo"` and `is_video == true`.

`ig_single_photo.json` — top-level `__typename == "GraphImage"` (no `edge_sidecar_to_children`).

If you cannot capture real fixtures right now, build minimal hand-rolled JSON with the exact field paths above. Save under `ReSerchTests/Fixtures/`.

- [ ] **Step 2: Add fixtures to the test target**

In Xcode: drag the `Fixtures/` folder into `ReSerchTests`, ensure "Copy items if needed" is OFF and target membership is `ReSerchTests` only. Verify they ship as bundle resources.

Run: `find ReSerchTests/Fixtures -name "*.json"`
Expected: three files listed.

- [ ] **Step 3: Write the failing tests**

Create `ReSerchTests/InstagramCarouselExtractorTests.swift`:

```swift
import XCTest
@testable import ReSerch

final class InstagramCarouselExtractorTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> [String: Any] {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func test_detectsSidecar() throws {
        let json = try loadFixture("ig_sidecar")
        XCTAssertEqual(InstagramCarouselExtractor.detectKind(from: json), .carousel)
    }

    func test_detectsMixedAsCarouselWithVideoFlag() throws {
        let json = try loadFixture("ig_mixed_sidecar")
        XCTAssertEqual(InstagramCarouselExtractor.detectKind(from: json), .mixedCarousel)
    }

    func test_detectsSinglePhotoAsNotCarousel() throws {
        let json = try loadFixture("ig_single_photo")
        XCTAssertEqual(InstagramCarouselExtractor.detectKind(from: json), .notCarousel)
    }

    func test_parsesSidecarIntoPayload() throws {
        let json = try loadFixture("ig_sidecar")
        let postURL = URL(string: "https://www.instagram.com/p/ABC123/")!
        let payload = try InstagramCarouselExtractor.parse(json: json, postURL: postURL)

        XCTAssertEqual(payload.platform, .instagram)
        XCTAssertEqual(payload.postURL, postURL)
        XCTAssertFalse(payload.creatorHandle.isEmpty)
        XCTAssertEqual(payload.creatorProfileURL.absoluteString, "https://www.instagram.com/\(payload.creatorHandle)/")
        XCTAssertGreaterThan(payload.slides.count, 1)
        XCTAssertEqual(payload.slides[0].index, 0)
        for slide in payload.slides {
            XCTAssertNotNil(slide.imageURL.scheme)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `xcodebuild -project ReSerch.xcodeproj -scheme ReSerch -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ReSerchTests/InstagramCarouselExtractorTests 2>&1 | tail -20`
Expected: 4 failures, "InstagramCarouselExtractor not defined" or similar.

- [ ] **Step 5: Implement the parser**

Create `ReSerch/InstagramCarouselExtractor.swift`:

```swift
import Foundation

enum InstagramCarouselExtractor {

    enum Kind: Equatable {
        case carousel       // pure photo sidecar
        case mixedCarousel  // sidecar with at least one video child
        case notCarousel    // single photo or video
    }

    enum ParseError: Error {
        case notASidecar
        case noChildren
        case missingOwner
    }

    static func detectKind(from json: [String: Any]) -> Kind {
        let edges = sidecarEdges(json)
        guard !edges.isEmpty else {
            return .notCarousel
        }
        let hasVideo = edges.contains { node in
            (node["is_video"] as? Bool == true)
                || (node["__typename"] as? String == "GraphVideo")
        }
        return hasVideo ? .mixedCarousel : .carousel
    }

    static func parse(json: [String: Any], postURL: URL) throws -> CarouselPayload {
        let edges = sidecarEdges(json)
        guard !edges.isEmpty else { throw ParseError.notASidecar }

        guard let owner = json["owner"] as? [String: Any],
              let handle = owner["username"] as? String,
              !handle.isEmpty else {
            throw ParseError.missingOwner
        }
        let displayName = (owner["full_name"] as? String) ?? handle
        let profileURL = URL(string: "https://www.instagram.com/\(handle)/")!

        let caption = (((json["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]])?
            .first?["node"] as? [String: Any])?["text"] as? String ?? ""
        let likeCount = (json["edge_media_preview_like"] as? [String: Any])?["count"] as? Int
        let postedTs = json["taken_at_timestamp"] as? TimeInterval
        let postedDate = postedTs.map { Date(timeIntervalSince1970: $0) }

        var slides: [CarouselSlide] = []
        for (i, node) in edges.enumerated() {
            guard let imageURL = imageURL(from: node) else { continue }
            slides.append(CarouselSlide(index: i, imageURL: imageURL))
        }
        guard !slides.isEmpty else { throw ParseError.noChildren }

        return CarouselPayload(
            platform: .instagram,
            postURL: postURL,
            creatorHandle: handle,
            creatorDisplayName: displayName,
            creatorProfileURL: profileURL,
            caption: caption,
            likeCount: likeCount,
            postedDate: postedDate,
            slides: slides
        )
    }

    private static func sidecarEdges(_ json: [String: Any]) -> [[String: Any]] {
        guard let sidecar = json["edge_sidecar_to_children"] as? [String: Any],
              let edges = sidecar["edges"] as? [[String: Any]] else { return [] }
        return edges.compactMap { $0["node"] as? [String: Any] }
    }

    private static func imageURL(from node: [String: Any]) -> URL? {
        if let s = node["display_url"] as? String, let u = URL(string: s) { return u }
        if let versions = node["image_versions2"] as? [String: Any],
           let candidates = versions["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let s = first["url"] as? String,
           let u = URL(string: s) { return u }
        return nil
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -project ReSerch.xcodeproj -scheme ReSerch -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ReSerchTests/InstagramCarouselExtractorTests 2>&1 | tail -20`
Expected: 4 tests passed.

- [ ] **Step 7: Commit**

```bash
git add ReSerch/InstagramCarouselExtractor.swift ReSerchTests/InstagramCarouselExtractorTests.swift ReSerchTests/Fixtures/ig_*.json
git commit -m "Parse Instagram carousel JSON into CarouselPayload"
```

---

## Task 4: TikTok photo-post JSON parser

**Files:**
- Create: `ReSerch/TikTokPhotoExtractor.swift`
- Test: `ReSerchTests/TikTokPhotoExtractorTests.swift`
- Fixtures: `ReSerchTests/Fixtures/tiktok_photo_post.json`, `tiktok_video_post.json`

- [ ] **Step 1: Capture two TikTok fixtures**

TikTok page JSON lives under `__UNIVERSAL_DATA_FOR_REHYDRATION__` → `__DEFAULT_SCOPE__["webapp.video-detail"].itemInfo.itemStruct`. For the test fixtures we save just the `itemStruct` object.

`tiktok_photo_post.json` — must have `imagePost.images[]`, each with `imageURL.urlList[]` (we use `urlList[0]`). Also `author.uniqueId`, `author.nickname`, `desc`, `stats.diggCount`, `createTime`, `id`. **Must NOT have `video.playAddr` populated.**

`tiktok_video_post.json` — has `video.playAddr` populated, no `imagePost`.

- [ ] **Step 2: Add fixtures to test target** (same drag-in step as Task 3 Step 2)

- [ ] **Step 3: Write the failing tests**

Create `ReSerchTests/TikTokPhotoExtractorTests.swift`:

```swift
import XCTest
@testable import ReSerch

final class TikTokPhotoExtractorTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> [String: Any] {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func test_detectsPhotoPost() throws {
        let json = try loadFixture("tiktok_photo_post")
        XCTAssertTrue(TikTokPhotoExtractor.isPhotoPost(itemStruct: json))
    }

    func test_videoPostIsNotPhotoPost() throws {
        let json = try loadFixture("tiktok_video_post")
        XCTAssertFalse(TikTokPhotoExtractor.isPhotoPost(itemStruct: json))
    }

    func test_parsesPhotoPostIntoPayload() throws {
        let json = try loadFixture("tiktok_photo_post")
        let postURL = URL(string: "https://www.tiktok.com/@user/photo/1234567890")!
        let payload = try TikTokPhotoExtractor.parse(itemStruct: json, postURL: postURL)

        XCTAssertEqual(payload.platform, .tiktok)
        XCTAssertFalse(payload.creatorHandle.isEmpty)
        XCTAssertEqual(payload.creatorProfileURL.absoluteString, "https://www.tiktok.com/@\(payload.creatorHandle)")
        XCTAssertGreaterThan(payload.slides.count, 0)
        XCTAssertEqual(payload.slides.first?.index, 0)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `xcodebuild ... test -only-testing:ReSerchTests/TikTokPhotoExtractorTests 2>&1 | tail -20`
Expected: 3 failures.

- [ ] **Step 5: Implement the parser**

Create `ReSerch/TikTokPhotoExtractor.swift`:

```swift
import Foundation

enum TikTokPhotoExtractor {

    enum ParseError: Error {
        case notPhotoPost
        case noImages
        case missingAuthor
    }

    static func isPhotoPost(itemStruct: [String: Any]) -> Bool {
        guard let imagePost = itemStruct["imagePost"] as? [String: Any],
              let images = imagePost["images"] as? [[String: Any]],
              !images.isEmpty else {
            return false
        }
        // Photo posts may still have a video stub; treat it as a photo post.
        return true
    }

    static func parse(itemStruct: [String: Any], postURL: URL) throws -> CarouselPayload {
        guard isPhotoPost(itemStruct: itemStruct) else { throw ParseError.notPhotoPost }
        guard let imagePost = itemStruct["imagePost"] as? [String: Any],
              let images = imagePost["images"] as? [[String: Any]] else {
            throw ParseError.noImages
        }
        guard let author = itemStruct["author"] as? [String: Any],
              let handle = author["uniqueId"] as? String,
              !handle.isEmpty else {
            throw ParseError.missingAuthor
        }
        let displayName = (author["nickname"] as? String) ?? handle
        let profileURL = URL(string: "https://www.tiktok.com/@\(handle)")!

        let caption = (itemStruct["desc"] as? String) ?? ""
        let likeCount = (itemStruct["stats"] as? [String: Any])?["diggCount"] as? Int
        let createTime = itemStruct["createTime"] as? TimeInterval
        let postedDate = createTime.map { Date(timeIntervalSince1970: $0) }

        var slides: [CarouselSlide] = []
        for (i, image) in images.enumerated() {
            guard let imageURL = imageURL(from: image) else { continue }
            slides.append(CarouselSlide(index: i, imageURL: imageURL))
        }
        guard !slides.isEmpty else { throw ParseError.noImages }

        return CarouselPayload(
            platform: .tiktok,
            postURL: postURL,
            creatorHandle: handle,
            creatorDisplayName: displayName,
            creatorProfileURL: profileURL,
            caption: caption,
            likeCount: likeCount,
            postedDate: postedDate,
            slides: slides
        )
    }

    private static func imageURL(from image: [String: Any]) -> URL? {
        guard let imageDict = image["imageURL"] as? [String: Any],
              let list = imageDict["urlList"] as? [String],
              let first = list.first(where: { URL(string: $0)?.scheme != nil }) else { return nil }
        return URL(string: first)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Expected: 3 tests passed.

- [ ] **Step 7: Commit**

```bash
git add ReSerch/TikTokPhotoExtractor.swift ReSerchTests/TikTokPhotoExtractorTests.swift ReSerchTests/Fixtures/tiktok_*.json
git commit -m "Parse TikTok photo posts into CarouselPayload"
```

---

## Task 5: `CarouselNoteFormatter`

**Files:**
- Create: `ReSerch/CarouselNoteFormatter.swift`
- Test: `ReSerchTests/CarouselNoteFormatterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ReSerch

final class CarouselNoteFormatterTests: XCTestCase {
    private func samplePayload(slideTexts: [String?], embedFilenames: [String?] = []) -> CarouselPayload {
        var slides: [CarouselSlide] = []
        for (i, t) in slideTexts.enumerated() {
            var slide = CarouselSlide(
                index: i,
                imageURL: URL(string: "https://cdn.example.com/\(i).jpg")!
            )
            slide.recognizedText = t
            if i < embedFilenames.count, let name = embedFilenames[i] {
                slide.localImagePath = URL(fileURLWithPath: "/tmp/\(name)")
            }
            slides.append(slide)
        }
        return CarouselPayload(
            platform: .instagram,
            postURL: URL(string: "https://www.instagram.com/p/ABC/")!,
            creatorHandle: "alice",
            creatorDisplayName: "Alice",
            creatorProfileURL: URL(string: "https://www.instagram.com/alice/")!,
            caption: "hello world",
            likeCount: 42,
            postedDate: nil,
            slides: slides
        )
    }

    func test_headerHasClickableLinks() {
        let md = CarouselNoteFormatter.format(samplePayload(slideTexts: ["a"]), embedImages: false)
        XCTAssertTrue(md.contains("[Alice](https://www.instagram.com/alice/)"))
        XCTAssertTrue(md.contains("[@alice](https://www.instagram.com/alice/)"))
        XCTAssertTrue(md.contains("[See post](https://www.instagram.com/p/ABC/)"))
    }

    func test_emptySlideRendersPlaceholder() {
        let md = CarouselNoteFormatter.format(samplePayload(slideTexts: ["text", nil]), embedImages: false)
        XCTAssertTrue(md.contains("## Slide 1"))
        XCTAssertTrue(md.contains("## Slide 2"))
        XCTAssertTrue(md.contains("*[no text detected]*"))
    }

    func test_embedImagesOnEmitsObsidianEmbed() {
        let payload = samplePayload(slideTexts: ["a", "b"], embedFilenames: ["abc-00.jpg", "abc-01.jpg"])
        let md = CarouselNoteFormatter.format(payload, embedImages: true)
        XCTAssertTrue(md.contains("![[abc-00.jpg]]"))
        XCTAssertTrue(md.contains("![[abc-01.jpg]]"))
    }

    func test_embedImagesOffOmitsEmbed() {
        let payload = samplePayload(slideTexts: ["a"], embedFilenames: ["abc-00.jpg"])
        let md = CarouselNoteFormatter.format(payload, embedImages: false)
        XCTAssertFalse(md.contains("![["))
    }

    func test_imageDownloadFailedRendersFallback() {
        var payload = samplePayload(slideTexts: ["a"])
        payload.slides[0].imageDownloadFailed = true
        let md = CarouselNoteFormatter.format(payload, embedImages: true)
        XCTAssertTrue(md.contains("*[image unavailable]*"))
    }

    func test_slideCountInHeader() {
        let md = CarouselNoteFormatter.format(samplePayload(slideTexts: ["a","b","c"]), embedImages: false)
        XCTAssertTrue(md.contains("**Slides:** 3"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: 6 failures, "CarouselNoteFormatter not defined."

- [ ] **Step 3: Implement the formatter**

```swift
import Foundation

enum CarouselNoteFormatter {
    static func format(_ payload: CarouselPayload, embedImages: Bool) -> String {
        var lines: [String] = []
        let profile = payload.creatorProfileURL.absoluteString

        lines.append("# [\(payload.creatorDisplayName)](\(profile)) — Carousel")
        lines.append("")
        if !payload.caption.isEmpty {
            lines.append("> \(payload.caption.replacingOccurrences(of: "\n", with: "\n> "))")
            lines.append("")
        }
        lines.append("**Creator:** [@\(payload.creatorHandle)](\(profile))")
        if let likes = payload.likeCount {
            lines.append("**Likes:** \(likes)")
        }
        lines.append("**Slides:** \(payload.slideCount)")
        lines.append("**Source:** [See post](\(payload.postURL.absoluteString))")
        lines.append("")
        lines.append("---")
        lines.append("")

        for slide in payload.slides {
            lines.append("## Slide \(slide.index + 1)")
            if embedImages {
                if slide.imageDownloadFailed {
                    lines.append("*[image unavailable]*")
                } else if let local = slide.localImagePath {
                    lines.append("![[\(local.lastPathComponent)]]")
                }
            }
            let text = (slide.recognizedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(text.isEmpty ? "*[no text detected]*" : text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ReSerch/CarouselNoteFormatter.swift ReSerchTests/CarouselNoteFormatterTests.swift
git commit -m "Format CarouselPayload as Obsidian Markdown with clickable header links"
```

---

## Task 6: `CarouselOCRService` (download + Vision OCR)

**Files:**
- Create: `ReSerch/CarouselOCRService.swift`

This task has no unit tests — it depends on real network + Vision. Smoke testing happens via the integration step in Task 9.

- [ ] **Step 1: Implement the service**

```swift
import Foundation
import Vision
import UIKit

@MainActor
final class CarouselOCRService {

    /// Where downloaded images go when the embed-images setting is on.
    /// Mirrors the existing thumbnail destination logic — keep them in the app's
    /// Documents directory under `CarouselImages/` so they're exportable to Obsidian.
    static func imagesDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = docs.appendingPathComponent("CarouselImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Process every slide. Returns the same payload with `recognizedText`,
    /// `localImagePath`, and `imageDownloadFailed` filled in.
    func process(
        _ payload: CarouselPayload,
        embedImages: Bool,
        progress: @escaping (Int, Int) -> Void
    ) async -> CarouselPayload {
        var payload = payload
        let total = payload.slides.count
        let postSlug = postSlug(for: payload.postURL)
        let dir = try? Self.imagesDirectory()

        // Bounded concurrency: 4 in flight max.
        await withTaskGroup(of: (Int, Data?).self) { group in
            var inflight = 0
            var iterator = payload.slides.makeIterator()
            var completed = 0

            func enqueueNext() {
                guard let slide = iterator.next() else { return }
                inflight += 1
                group.addTask { [imageURL = slide.imageURL, index = slide.index] in
                    let data = try? await Self.download(imageURL)
                    return (index, data)
                }
            }
            for _ in 0..<min(4, total) { enqueueNext() }

            while let (index, data) = await group.next() {
                inflight -= 1
                completed += 1
                progress(completed, total)

                guard let data, let image = UIImage(data: data) else {
                    payload.slides[index].imageDownloadFailed = true
                    enqueueNext()
                    continue
                }

                if embedImages, let dir {
                    let filename = String(format: "%@-%02d.jpg", postSlug, index)
                    let dest = dir.appendingPathComponent(filename)
                    try? data.write(to: dest)
                    payload.slides[index].localImagePath = dest
                }

                let text = await Self.runOCR(on: image)
                payload.slides[index].recognizedText = text

                enqueueNext()
            }
        }

        return payload
    }

    private static func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    /// Runs Vision OCR on an image. Returns "" if no text, nil if it timed out / errored.
    private static func runOCR(on image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            // 10s timeout per slide
            let task = Task.detached {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                request.cancel()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: nil)
                }
                task.cancel()
            }
        }
    }

    private func postSlug(for url: URL) -> String {
        // Pull the last meaningful path component, sanitize for filename use.
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let raw = parts.last ?? "carousel"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).replacingOccurrences(of: "--", with: "-")
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild ... build -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ReSerch/CarouselOCRService.swift
git commit -m "Add CarouselOCRService: bounded-concurrency download + Vision OCR"
```

---

## Task 7: Wire `InstagramWebExtractor` to detect carousels

**Files:**
- Modify: `ReSerch/InstagramWebExtractor.swift`

Goal: when the API JSON arrives, check kind. If carousel/mixedCarousel, complete with a carousel result variant instead of waiting for the video URL.

- [ ] **Step 1: Find where API JSON is parsed**

Run: `grep -n "apiJSON\|GraphSidecar\|edge_sidecar" ReSerch/InstagramWebExtractor.swift`
Identify the spot where `apiJSON` is set — that is the branch point.

- [ ] **Step 2: Add a result variant**

At the top of the file, replace `InstagramWebResult` with:

```swift
enum InstagramWebResult {
    case video(InstagramVideoResult)
    case carousel(CarouselPayload, hasVideo: Bool)
}

struct InstagramVideoResult {
    let videoURL: URL
    let apiJSON: [String: Any]?
    let domMeta: [String: Any]?
}
```

Update all internal call sites that previously created `InstagramWebResult(videoURL:apiJSON:domMeta:)` to wrap in `.video(InstagramVideoResult(...))`.

- [ ] **Step 3: Branch when API JSON arrives**

Right after `apiJSON` is assigned (or once both DOM and API JSON have been gathered, whichever is the existing settle point), insert:

```swift
if let json = apiJSON {
    let kind = InstagramCarouselExtractor.detectKind(from: json)
    if kind == .carousel || kind == .mixedCarousel {
        if let postURL = self.webView?.url ?? self.startURL,
           let payload = try? InstagramCarouselExtractor.parse(json: json, postURL: postURL) {
            self.resolve(.carousel(payload, hasVideo: kind == .mixedCarousel))
            return
        }
    }
}
```

(If `startURL` doesn't exist, capture the URL when the extractor starts — store it in a new `private let startURL: URL` property set in `init`. If the extractor already has a stored URL, use that name.)

- [ ] **Step 4: Update callers**

Run: `grep -rn "InstagramWebResult\|InstagramWebExtractor" ReSerch/ --include="*.swift" | grep -v InstagramWebExtractor.swift`

For each caller, switch on the new enum:

```swift
switch result {
case .video(let v):
    // existing logic, was: result.videoURL etc
case .carousel(let payload, let hasVideo):
    // hand off to CarouselCoordinator (Task 8)
}
```

If a caller uses `result.videoURL` directly, change to `v.videoURL` after the switch destructures.

- [ ] **Step 5: Build**

Expected: BUILD SUCCEEDED. Fix any remaining call sites until it builds.

- [ ] **Step 6: Commit**

```bash
git add ReSerch/InstagramWebExtractor.swift ReSerch/<any caller files touched>
git commit -m "InstagramWebExtractor: detect carousels and emit carousel result variant"
```

---

## Task 8: `CarouselCoordinator` (extract → OCR → format → TranscriptResult)

**Files:**
- Create: `ReSerch/CarouselCoordinator.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation

@MainActor
final class CarouselCoordinator {

    private let ocr = CarouselOCRService()

    func makeTranscriptResult(
        from payload: CarouselPayload,
        embedImages: Bool,
        progress: @escaping (String) -> Void
    ) async -> TranscriptResult {
        progress("Extracting slide 1 of \(payload.slideCount)…")
        let processed = await ocr.process(payload, embedImages: embedImages) { done, total in
            progress("Extracting slide \(done) of \(total)…")
        }
        let markdown = CarouselNoteFormatter.format(processed, embedImages: embedImages)

        let title = "\(processed.creatorDisplayName) — Carousel (\(processed.slideCount) slides)"
        return TranscriptResult(
            title: title,
            author: processed.creatorDisplayName,
            handle: processed.creatorHandle,
            platform: processed.platform.rawValue,
            url: processed.postURL.absoluteString,
            caption: processed.caption,
            transcript: markdown,
            likeCount: processed.likeCount,
            postedDate: processed.postedDate,
            thumbnailURL: processed.slides.first?.imageURL
        )
    }
}
```

- [ ] **Step 2: Build**

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ReSerch/CarouselCoordinator.swift
git commit -m "Add CarouselCoordinator: orchestrate OCR and produce TranscriptResult"
```

---

## Task 9: Hook the Instagram carousel branch into the URL paste flow

**Files:**
- Modify: the file that drives URL submission. Most likely `ReSerch/AddTranscriptView.swift` or `ReSerch/TranscriptViewModel.swift` — find the call site where `InstagramWebExtractor` is invoked.

- [ ] **Step 1: Locate the call site**

Run: `grep -rn "InstagramWebExtractor()" ReSerch/ --include="*.swift"`

- [ ] **Step 2: Add the carousel branch**

At the call site, where the result is handled, add the `.carousel` case:

```swift
@AppStorage("embedCarouselImages") var embedCarouselImages: Bool = true

// inside the result handler:
case .carousel(let payload, let hasVideo):
    if hasVideo {
        // Mixed carousel — surface a non-blocking notice. v2 will handle these properly.
        self.showToast("Mixed carousel — videos in this post weren't transcribed.")
    }
    let coordinator = CarouselCoordinator()
    let result = await coordinator.makeTranscriptResult(
        from: payload,
        embedImages: embedCarouselImages,
        progress: { [weak self] message in
            self?.progressMessage = message
        }
    )
    await self.persist(result)  // use whatever the existing persistence call is
```

If there is no existing `showToast` helper, drop the call and leave a one-line `// TODO(v2): mixed carousels` — but the toast is preferred. Match existing UI feedback patterns first.

- [ ] **Step 3: Build and test on simulator**

Run: `xcodebuild ... build -quiet`. Then on simulator:
1. Launch app.
2. Paste a known IG carousel URL.
3. Verify progress shows "Extracting slide N of M…".
4. Verify resulting note has `## Slide 1`, clickable handle and "See post" links, image embeds (if toggle on).
5. Toggle off "Embed images in carousel notes" in Settings, paste a different carousel, verify no `![[...]]` lines appear.

- [ ] **Step 4: Commit**

```bash
git add ReSerch/<modified files>
git commit -m "Route Instagram carousels through CarouselCoordinator"
```

---

## Task 10: TikTok photo-post integration

**Files:**
- Modify: the TikTok extractor / page handler (find with `grep -rn "TikTok" ReSerch/ --include="*.swift" | grep -i "extract\|fetch"`).

TikTok scraping in this project happens through `TikTokPlayerView` / a similar WKWebView path. The page JSON includes the `__UNIVERSAL_DATA_FOR_REHYDRATION__` blob which contains `itemStruct`.

- [ ] **Step 1: Reach the TikTok page-JSON parse site**

Run: `grep -rn "UNIVERSAL_DATA_FOR_REHYDRATION\|itemStruct\|webapp.video-detail" ReSerch/ --include="*.swift"`
If no match, the existing TikTok flow doesn't read page JSON yet. In that case, add a JS-eval to the existing TikTok WKWebView that grabs the JSON:

```js
JSON.stringify(
  JSON.parse(document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__').textContent)
    ['__DEFAULT_SCOPE__']['webapp.video-detail']?.itemInfo?.itemStruct ?? {}
)
```

Hand the parsed dictionary to the branching logic below.

- [ ] **Step 2: Branch on photo vs video**

```swift
if TikTokPhotoExtractor.isPhotoPost(itemStruct: itemStruct),
   let payload = try? TikTokPhotoExtractor.parse(itemStruct: itemStruct, postURL: postURL) {
    // dispatch to CarouselCoordinator (same pattern as Task 9)
    let coordinator = CarouselCoordinator()
    let result = await coordinator.makeTranscriptResult(
        from: payload,
        embedImages: embedCarouselImages,
        progress: { message in self.progressMessage = message }
    )
    await self.persist(result)
    return
}
// else: fall through to existing video path
```

- [ ] **Step 3: Build and test on simulator**

Paste a known TikTok photo-post URL. Verify same as Task 9 Step 3.

- [ ] **Step 4: Commit**

```bash
git add ReSerch/<modified files>
git commit -m "Route TikTok photo posts through CarouselCoordinator"
```

---

## Task 11: History list icon for carousels

**Files:**
- Modify: the history list cell view (find with `grep -rn "platform" ReSerch/ --include="*.swift" | grep -i "icon\|symbol\|image"`).

- [ ] **Step 1: Add icon mapping**

Wherever the platform icon is selected for a `TranscriptResult`, add:

```swift
if result.platform.contains("Carousel") || result.platform.contains("Photos") {
    Image(systemName: "square.stack")
}
```

Keep the existing video-platform branches intact.

- [ ] **Step 2: Build and verify on simulator**

Open history. Carousel notes now show the stack icon.

- [ ] **Step 3: Commit**

```bash
git add ReSerch/<modified files>
git commit -m "Show stack icon for carousel notes in history"
```

---

## Self-Review Notes

- Spec coverage: detection (Tasks 7, 10), extractors (3, 4), OCR + image embed (6), formatter with clickable links (5), settings toggle (2), edge cases — empty OCR (5), mixed carousel toast (9), image download failure (5, 6), per-slide timeout (6) — all covered.
- Out-of-scope items (mixed video+photo full handling, translation, bulk) are explicitly deferred and not in any task.
- Type names used in later tasks (`CarouselPayload`, `CarouselSlide`, `InstagramCarouselExtractor.Kind`, `CarouselPlatform`, `CarouselNoteFormatter.format`) all match Tasks 1, 3, 5.

## Open Risks for the Implementer

1. **WKWebView timing in `InstagramWebExtractor`.** That file has a long-standing race between API-JSON arrival and video-URL interception. When adding the carousel branch, do not break the existing video path — gate the new branch on `kind == .carousel || .mixedCarousel`, and ensure `resolve(.carousel(...))` cancels the video pollers/timers the same way the existing `resolve` does. Re-read the file's "resolve() handles all UIKit/timer cleanup" comment before editing.
2. **Image filename collisions across carousels.** `postSlug` is derived from the URL's last path component. IG and TikTok both have unique post IDs there, so collisions are unlikely — but if a user re-fetches the same post, files overwrite. That is acceptable v1 behavior.
3. **Vision recognition order.** Default top-to-bottom, left-to-right works for most carousel slides. If real captures look scrambled, the targeted fix is to sort `observations` by `boundingBox.minY` descending then `minX` ascending before joining. Do NOT pre-emptively change this — verify with real data first.
