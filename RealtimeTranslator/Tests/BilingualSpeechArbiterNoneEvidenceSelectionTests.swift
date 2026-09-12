import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterNoneEvidenceSelectionTests: XCTestCase {
    func testFallsBackToConfidenceWhenNeitherLaneHasScriptEvidence() {
        // Given: 日英どちらも記号だけで言語証拠がない同一区間
        var arbiter = BilingualSpeechArbiter()
        XCTAssertEqual(SpokenLanguageDetector.evidence(in: "!!!"), .none)
        XCTAssertEqual(SpokenLanguageDetector.evidence(in: "???"), .none)
        _ = arbiter.submit(
            candidate(
                text: "!!!",
                language: .japanese,
                confidence: 0.4,
                start: 0,
                end: 1
            )
        )

        // When: 対向レーンの高信頼度な記号列が届く
        let selected = arbiter.submit(
            candidate(
                text: "???",
                language: .english,
                confidence: 0.9,
                start: 0,
                end: 1
            )
        )

        // Then: 証拠なしで選択不能にせず、信頼度の高い英語レーンへ固定する
        XCTAssertEqual(selected?.language, .english)
        XCTAssertEqual(selected?.text, "???")
        XCTAssertEqual(arbiter.activeLanguage, .english)
    }

    func testSelectBestAvailableFallsBackWhenOnlySymbolCandidatesRemain() {
        // Given: 対向レーンが来ず、記号だけの日本語候補が残っている判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "!!!",
                language: .japanese,
                confidence: 0.7,
                start: 0,
                end: 1
            )
        )

        // When: 対向待ち期限後に最良候補を選ぶ
        let selected = arbiter.selectBestAvailable()

        // Then: `.none`を除外し切らず、残った候補でレーンを固定する
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "!!!")
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    private func candidate(
        text: String,
        language: SpokenLanguage,
        confidence: Double,
        isFinal: Bool = false,
        start: Double,
        end: Double
    ) -> SpeechRecognitionCandidate {
        SpeechRecognitionCandidate(
            text: text,
            language: language,
            confidence: confidence,
            isFinal: isFinal,
            startTime: start,
            endTime: end
        )
    }
}
