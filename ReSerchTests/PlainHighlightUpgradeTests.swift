import Testing
import Foundation
@testable import ReSerch

/// Unit tests for the side-peek "plain highlight → footnote" upgrade flow.
/// The transcript-text transformation is factored out as static helpers on
/// TranscriptDetailView so we can exercise the tricky bits — duplicate
/// highlight text, existing footnote indices — without driving SwiftUI.
@Suite("Plain highlight upgrade")
struct PlainHighlightUpgradeTests {

    // MARK: - nextFootnoteIndex

    @Test func nextFootnoteIndex_emptyTranscript_returnsOne() {
        #expect(TranscriptDetailView.nextFootnoteIndex(in: "") == 1)
    }

    @Test func nextFootnoteIndex_noFootnotes_returnsOne() {
        let transcript = "Just some text with ==a highlight== and nothing else."
        #expect(TranscriptDetailView.nextFootnoteIndex(in: transcript) == 1)
    }

    @Test func nextFootnoteIndex_skipsPastExistingMax() {
        let transcript = """
        First ==one==[^1] and then ==two==[^2].

        [^1]: note one
        [^2]: note two
        """
        #expect(TranscriptDetailView.nextFootnoteIndex(in: transcript) == 3)
    }

    @Test func nextFootnoteIndex_handlesGaps() {
        // [^1] and [^5] exist with no [^2..4] — still pick past the max so we
        // never collide with anything that already lives in the document.
        let transcript = """
        ==one==[^1] ==five==[^5]

        [^1]: one
        [^5]: five
        """
        #expect(TranscriptDetailView.nextFootnoteIndex(in: transcript) == 6)
    }

    // MARK: - applyPlainHighlightUpgrade

    @Test func upgrade_basicHighlight_attachesFootnoteAndAppendsDefinition() throws {
        let transcript = "Hello, ==world==, and beyond."
        let ns = transcript as NSString
        let range = ns.range(of: "==world==")

        let result = try #require(TranscriptDetailView.applyPlainHighlightUpgrade(
            transcript: transcript,
            fullRange: range
        ))

        #expect(result.footnoteIndex == 1)
        #expect(result.transcript.contains("==world==[^1]"))
        #expect(result.transcript.contains("\n[^1]: "))
        // Definition should be at the END, after a blank-line separator.
        #expect(result.transcript.hasSuffix("[^1]: "))
    }

    @Test func upgrade_secondOfDuplicateHighlights_modifiesOnlyTheSpecifiedRange() throws {
        // Two identical ==flow== highlights. We pass the SECOND occurrence's
        // range — only that one should pick up the [^1], the first stays plain.
        let transcript = "First ==flow== and again later ==flow== for emphasis."
        let ns = transcript as NSString
        let firstRange = ns.range(of: "==flow==")
        let searchAfter = NSRange(location: firstRange.location + firstRange.length,
                                  length: ns.length - (firstRange.location + firstRange.length))
        let secondRange = ns.range(of: "==flow==", options: [], range: searchAfter)

        let result = try #require(TranscriptDetailView.applyPlainHighlightUpgrade(
            transcript: transcript,
            fullRange: secondRange
        ))

        // First occurrence stays untouched (no footnote attached).
        let firstChunk = (result.transcript as NSString).substring(with: NSRange(location: 0, length: 30))
        #expect(firstChunk.contains("==flow=="))
        #expect(!firstChunk.contains("==flow==[^"))

        // Second occurrence picked up [^1].
        #expect(result.transcript.contains("later ==flow==[^1]"))
        // And exactly one [^1]: definition was appended.
        let definitionCount = result.transcript.components(separatedBy: "[^1]: ").count - 1
        #expect(definitionCount == 1)
    }

    @Test func upgrade_withExistingFootnotes_picksUnusedIndex() throws {
        let transcript = """
        Already ==annotated==[^1] earlier. Now a plain ==fresh== one.

        [^1]: existing
        """
        let ns = transcript as NSString
        let range = ns.range(of: "==fresh==")

        let result = try #require(TranscriptDetailView.applyPlainHighlightUpgrade(
            transcript: transcript,
            fullRange: range
        ))

        #expect(result.footnoteIndex == 2)
        #expect(result.transcript.contains("==fresh==[^2]"))
        // Existing [^1] line preserved verbatim.
        #expect(result.transcript.contains("[^1]: existing"))
        // New [^2]: line appended.
        #expect(result.transcript.contains("[^2]: "))
    }

    @Test func upgrade_refusesAlreadyAnnotatedHighlight() {
        // Defense in depth: if a stale range somehow points at a footnote-backed
        // highlight, we must not double-annotate it.
        let transcript = "Already ==done==[^1] here.\n\n[^1]: yes"
        let ns = transcript as NSString
        let range = ns.range(of: "==done==")
        let result = TranscriptDetailView.applyPlainHighlightUpgrade(
            transcript: transcript,
            fullRange: range
        )
        #expect(result == nil)
    }

    @Test func upgrade_invalidRange_returnsNil() {
        let transcript = "==valid== highlight"
        let bogus = NSRange(location: 999, length: 5)
        #expect(TranscriptDetailView.applyPlainHighlightUpgrade(transcript: transcript, fullRange: bogus) == nil)
    }
}

/// The footnote serialization must preserve paragraph breaks inside multi-line
/// comments. CommonMark requires continuation lines to be indented (4 spaces)
/// so they stay attached to `[^n]`; without that, the second paragraph leaks
/// into the transcript body as plain text.
@Suite("Footnote multiline round-trip")
struct FootnoteMultilineTests {

    @Test func serialize_singleLine() {
        let out = TranscriptDetailView.serializeFootnote(index: "1", comment: "just one line")
        #expect(out == "[^1]: just one line")
    }

    @Test func serialize_multipleParagraphs_indentsContinuations() {
        let comment = "First paragraph.\n\nSecond paragraph.\n\nThird."
        let out = TranscriptDetailView.serializeFootnote(index: "1", comment: comment)
        let expected = """
        [^1]: First paragraph.

            Second paragraph.

            Third.
        """
        #expect(out == expected)
    }

    @Test func roundTrip_singleLineFootnote() {
        let comment = "hello world"
        let serialized = TranscriptDetailView.serializeFootnote(index: "1", comment: comment)
        let parsed = TranscriptDetailView.parseFootnoteDefinitions(in: serialized)
        #expect(parsed["1"] == comment)
    }

    @Test func roundTrip_multiparagraphFootnote() {
        let comment = """
        Seeing this give me more courage to try to not appeal to everyone.

        Not knocking on anyone's expression, but there are people who practice movement for the craft.

        And of course there's nuance in between.
        """
        let serialized = TranscriptDetailView.serializeFootnote(index: "7", comment: comment)
        let parsed = TranscriptDetailView.parseFootnoteDefinitions(in: serialized)
        #expect(parsed["7"] == comment)
    }

    @Test func roundTrip_softNewlinesWithinParagraph() {
        // User pressed a single Return (not paragraph break) — should also survive.
        let comment = "line one\nline two\nline three"
        let serialized = TranscriptDetailView.serializeFootnote(index: "2", comment: comment)
        let parsed = TranscriptDetailView.parseFootnoteDefinitions(in: serialized)
        #expect(parsed["2"] == comment)
    }

    @Test func parse_continuationDoesNotLeakIntoBodyText() {
        let transcript = """
        Some transcript text that ends here.

        [^1]: First paragraph.

            Second paragraph.

        Body text that is NOT part of the footnote.
        """
        let parsed = TranscriptDetailView.parseFootnoteDefinitions(in: transcript)
        #expect(parsed["1"] == "First paragraph.\n\nSecond paragraph.")
        // The "Body text..." line is not indented, so it must NOT have been
        // absorbed as a continuation of [^1].
    }

    @Test func write_replacesEntireMultilineBlock() {
        let original = """
        Body ==here==[^1] more body.

        [^1]: old first paragraph.

            old second paragraph.

            old third paragraph.
        """
        let updated = TranscriptDetailView.writeFootnoteDefinition(
            transcript: original,
            index: "1",
            comment: "new line"
        )
        // Old continuations are gone — none of "old second" survived.
        #expect(!updated.contains("old second"))
        #expect(!updated.contains("old third"))
        #expect(updated.contains("[^1]: new line"))
        // Body sentence outside the footnote stays intact.
        #expect(updated.contains("Body ==here==[^1] more body."))
    }

    @Test func write_promoteSingleLineToMultiline() {
        let original = "Body ==x==[^1]\n\n[^1]: old single"
        let updated = TranscriptDetailView.writeFootnoteDefinition(
            transcript: original,
            index: "1",
            comment: "para one\n\npara two"
        )
        let parsed = TranscriptDetailView.parseFootnoteDefinitions(in: updated)
        #expect(parsed["1"] == "para one\n\npara two")
    }

    @Test func write_otherFootnotesUntouched() {
        let original = """
        ==a==[^1] and ==b==[^2]

        [^1]: keep me
        [^2]: replace me

            with this continuation
        """
        let updated = TranscriptDetailView.writeFootnoteDefinition(
            transcript: original,
            index: "2",
            comment: "fresh"
        )
        let parsed = TranscriptDetailView.parseFootnoteDefinitions(in: updated)
        #expect(parsed["1"] == "keep me")
        #expect(parsed["2"] == "fresh")
        #expect(!updated.contains("with this continuation"))
    }
}
