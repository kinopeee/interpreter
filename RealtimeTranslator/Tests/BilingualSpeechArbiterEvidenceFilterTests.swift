import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterEvidenceFilterTests: XCTestCase {
    func testVolatileAmbiguousLatinDoesNotBeatJapaneseEvidence() {
        // Given: 英語レーンが固有名詞1語だけを高信頼度で先に出した判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "Cursor",
                language: .english,
                confidence: 0.99
            )
        )

        // When: 日本語文字を含む対向候補が届く
        let selected = arbiter.submit(
            candidate(
                text: "テストです",
                language: .japanese,
                confidence: 0.4
            )
        )

        // Then: 曖昧Latinのvolatileは選抜母集団から除き、日本語レーンを固定する
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "テストです")
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testSymbolOnlyOppositeLaneDoesNotCompeteWithJapaneseEvidence() {
        // Given: 英語レーンが記号だけの高信頼度候補を先に出した判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "!!!",
                language: .english,
                confidence: 0.99
            )
        )

        // When: 日本語文字を含む対向候補が届く
        let selected = arbiter.submit(
            candidate(
                text: "テストです",
                language: .japanese,
                confidence: 0.4
            )
        )

        // Then: 文字種証拠のない記号候補は比較せず、日本語レーンを選ぶ
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "テストです")
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testOverlappingCandidateAfterFinalizeIsIgnored() {
        // Given: 0-1秒の区間で日本語レーンを確定した判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "hello there",
                language: .english,
                confidence: 0.4,
                start: 0,
                end: 1
            )
        )
        let finalized = arbiter.submit(
            candidate(
                text: "確定しました",
                language: .japanese,
                confidence: 0.9,
                isFinal: true,
                start: 0,
                end: 1
            )
        )

        // When: 確定済み区間と50%以上重なる遅延候補が届く
        let overlapping = arbiter.submit(
            candidate(
                text: "続きの発話",
                language: .japanese,
                confidence: 0.8,
                start: 0.3,
                end: 1.2
            )
        )

        // Then: 同じ発話の二重表示を防ぐため破棄し、次区間として残さない
        XCTAssertEqual(finalized?.language, .japanese)
        XCTAssertTrue(finalized?.isFinal == true)
        XCTAssertNil(overlapping)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertFalse(arbiter.hasPendingCandidates)
        XCTAssertEqual(arbiter.pendingRangeCount, 0)
    }

    private func candidate(
        text: String,
        language: SpokenLanguage,
        confidence: Double,
        isFinal: Bool = false,
        start: Double = 0,
        end: Double? = nil
    ) -> SpeechRecognitionCandidate {
        SpeechRecognitionCandidate(
            text: text,
            language: language,
            confidence: confidence,
            isFinal: isFinal,
            startTime: start,
            endTime: end ?? start + 1
        )
    }
}
