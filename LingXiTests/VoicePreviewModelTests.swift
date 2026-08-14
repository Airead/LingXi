import Foundation
import Testing
@testable import LingXi

@MainActor
struct VoicePreviewModelTests {

    private func makeSetup(
        text: String = "polished",
        original: String? = "raw",
        modes: [EnhanceMode] = [
            EnhanceMode(id: "proofread", label: "纠错润色", order: 1, prompt: "p1"),
            EnhanceMode(id: "translate_en", label: "翻译为英文", order: 2, prompt: "p2"),
        ],
        currentModeID: String = "proofread",
        isCached: Bool = false
    ) -> VoicePreviewSetup {
        VoicePreviewSetup(
            text: text,
            original: original,
            asrInfo: "apple · 3.2s",
            modes: modes,
            currentModeID: currentModeID,
            llmOptions: [LLMSelection(provider: "p1", model: "m1")],
            currentLLM: LLMSelection(provider: "p1", model: "m1"),
            isCached: isCached,
            history: []
        )
    }

    // MARK: - Init derivation

    @Test func enhancedSetupSplitsIntoThreeAreas() {
        let model = VoicePreviewModel(setup: makeSetup())
        #expect(model.asrText == "raw")
        #expect(model.enhancedText == "polished")
        #expect(model.finalText == "polished")
        #expect(model.enhanceState == .result(cached: false))
    }

    @Test func plainSetupHasNoEnhancedText() {
        let model = VoicePreviewModel(setup: makeSetup(text: "raw", original: nil, currentModeID: "off"))
        #expect(model.asrText == "raw")
        #expect(model.enhancedText == nil)
        #expect(model.finalText == "raw")
        #expect(model.enhanceState == .off)
    }

    @Test func initialFailureShowsRevertedState() {
        // Enhance was on (mode != off) but delivery carried no enhanced text.
        let model = VoicePreviewModel(setup: makeSetup(text: "raw", original: nil, currentModeID: "proofread"))
        #expect(model.enhanceState == .reverted)
    }

    // MARK: - Segments (⌘1 = Off)

    @Test func segmentsStartWithOff() {
        let model = VoicePreviewModel(setup: makeSetup())
        #expect(model.segments.map(\.id) == [EnhanceMode.offModeID, "proofread", "translate_en"])
        #expect(model.segments[0].label == "Off")
    }

    // MARK: - apply()

    @Test func applyResultUpdatesEnhanceAndFinal() {
        let model = VoicePreviewModel(setup: makeSetup())
        model.isEnhancing = true
        model.apply(
            text: "translated", original: "raw",
            currentModeID: "translate_en",
            currentLLM: LLMSelection(provider: "p1", model: "m1"),
            isCached: false
        )
        #expect(model.enhancedText == "translated")
        #expect(model.finalText == "translated")
        #expect(model.currentModeID == "translate_en")
        #expect(model.isEnhancing == false)
        #expect(model.enhanceState == .result(cached: false))
    }

    @Test func applyCachedResultShowsCachedState() {
        let model = VoicePreviewModel(setup: makeSetup())
        model.apply(
            text: "polished", original: "raw",
            currentModeID: "proofread", currentLLM: nil, isCached: true
        )
        #expect(model.enhanceState == .result(cached: true))
    }

    @Test func applyOffShowsASRTextAsFinal() {
        let model = VoicePreviewModel(setup: makeSetup())
        model.apply(
            text: "raw", original: nil,
            currentModeID: EnhanceMode.offModeID, currentLLM: nil, isCached: false
        )
        #expect(model.enhancedText == nil)
        #expect(model.finalText == "raw")
        #expect(model.enhanceState == .off)
    }

    @Test func applyDegradeShowsRevertedState() {
        let model = VoicePreviewModel(setup: makeSetup())
        model.apply(
            text: "raw", original: nil,
            currentModeID: "proofread", currentLLM: nil, isCached: false
        )
        #expect(model.enhancedText == nil)
        #expect(model.finalText == "raw")
        #expect(model.enhanceState == .reverted)
    }

    // MARK: - userEdited protection

    @Test func userEditBlocksFinalTextOverwrite() {
        let model = VoicePreviewModel(setup: makeSetup())
        model.finalText = "my edit"
        model.userEdited = true

        model.apply(
            text: "translated", original: "raw",
            currentModeID: "translate_en", currentLLM: nil, isCached: false
        )
        // The enhance area updates but the user's final text is preserved.
        #expect(model.enhancedText == "translated")
        #expect(model.finalText == "my edit")
    }

    @Test func enhancingStateWhileWaiting() {
        let model = VoicePreviewModel(setup: makeSetup())
        model.isEnhancing = true
        #expect(model.enhanceState == .enhancing)
    }

    // MARK: - Transcribing phase

    private func makeTranscribingSetup(currentModeID: String = "proofread") -> VoicePreviewSetup {
        var setup = makeSetup(text: "", original: nil, currentModeID: currentModeID)
        setup.isTranscribing = true
        return setup
    }

    @Test func transcribingSetupStartsEmptyAndPending() {
        let model = VoicePreviewModel(setup: makeTranscribingSetup())
        #expect(model.isTranscribing == true)
        #expect(model.asrText == "")
        #expect(model.finalText == "")
        #expect(model.enhancedText == nil)
        // Mode is on but there is nothing to enhance yet: no state label.
        #expect(model.enhanceState == .pending)
    }

    @Test func asrResultFillsASRAndFinal() {
        let model = VoicePreviewModel(setup: makeTranscribingSetup())
        model.applyASRResult(text: "hello", asrInfo: "apple · 2.0s")
        #expect(model.isTranscribing == false)
        #expect(model.asrText == "hello")
        #expect(model.asrInfo == "apple · 2.0s")
        #expect(model.finalText == "hello")
    }

    @Test func asrResultRespectsUserEdit() {
        let model = VoicePreviewModel(setup: makeTranscribingSetup())
        model.finalText = "typed while waiting"
        model.userEdited = true
        model.applyASRResult(text: "hello", asrInfo: "apple")
        #expect(model.asrText == "hello")
        #expect(model.finalText == "typed while waiting")
    }

    @Test func asrFailureKeepsPanelInPendingState() {
        let model = VoicePreviewModel(setup: makeTranscribingSetup())
        model.applyASRFailure(message: "Transcription failed")
        #expect(model.isTranscribing == false)
        #expect(model.asrFailureMessage == "Transcription failed")
        // No misleading "Failed, using ASR text" label for the enhancer.
        #expect(model.enhanceState == .pending)
    }

    @Test func offModeDuringTranscribingShowsOffState() {
        let model = VoicePreviewModel(setup: makeTranscribingSetup(currentModeID: EnhanceMode.offModeID))
        #expect(model.enhanceState == .off)
    }
}
