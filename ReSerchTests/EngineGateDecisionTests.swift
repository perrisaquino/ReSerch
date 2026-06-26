import Testing
@testable import ReSerch

/// Regression guard for the "forced to re-download the transcription engine"
/// bug. The old gate was effectively `ready ? proceed : needsModel`, so ANY
/// not-ready state — including "engine files are on disk but the pipeline just
/// hasn't loaded yet / failed to load" — dumped the user into the ~150MB
/// download screen. The fix splits availability three ways; only a genuinely
/// MISSING engine may route to `.needsModel`.
@Suite("Engine gate decision")
struct EngineGateDecisionTests {

    @Test func readyProceeds() {
        #expect(TranscriptViewModel.engineGateDecision(.ready) == .proceed)
    }

    @Test func missingShowsDownload() {
        #expect(TranscriptViewModel.engineGateDecision(.missing) == .needsModel)
    }

    /// THE bug: files present on disk but the load didn't succeed must NOT be
    /// treated as a missing engine. It's a retryable load error, never a
    /// re-download prompt.
    @Test func loadFailedIsRetryNotRedownload() {
        let decision = TranscriptViewModel.engineGateDecision(.loadFailed)
        #expect(decision == .loadError)
        #expect(decision != .needsModel)
    }
}
