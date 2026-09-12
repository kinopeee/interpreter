import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterFinalMergeEndTimeTests: XCTestCase {
    func testMergedSameLanguageFinalsPreferLaterEndTime() {
        // Given: 離れた2区間に同じ日本語finalが先行している判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "短い",
                language: .japanese,
                confidence: 0.8,
                isFinal: true,
                start: 0,
                end: 1
            )
        )
        _ = arbiter.submit(
            candidate(
                text: "短く改定された文",
                language: .japanese,
                confidence: 0.7,
                isFinal: true,
                start: 3,
                end: 4
            )
        )
        XCTAssertEqual(arbiter.pendingRangeCount, 2)

        // When: 先の区間が伸びて後続bucketと重なり、同一言語のfinal同士が統合される
        _ = arbiter.submit(
            candidate(
                text: "短い続き",
                language: .japanese,
                confidence: 0.85,
                isFinal: true,
                start: 0,
                end: 3.5
            )
        )
        XCTAssertEqual(arbiter.pendingRangeCount, 1)
        let selected = arbiter.selectBestAvailable()

        // Then: 終了時刻が遅いfinalを残し、短い仮説で長い確定文を上書きしない
        XCTAssertEqual(arbiter.pendingRangeCount, 0)
        XCTAssertEqual(selected?.text, "短く改定された文")
        XCTAssertEqual(selected?.endTime, 4)
        XCTAssertTrue(selected?.isFinal == true)
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
