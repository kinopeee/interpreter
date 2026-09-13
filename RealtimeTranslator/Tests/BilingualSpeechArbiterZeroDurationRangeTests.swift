import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterZeroDurationRangeTests: XCTestCase {
    func testZeroDurationRangesNearTheSameStartPairAsOneUtterance() {
        // Given: 開始=終了の点区間として届いた日本語候補
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                language: .japanese,
                confidence: 0.9,
                start: 1.0,
                end: 1.0
            )
        )

        // When: 0.05秒だけ後の英語点区間が届く
        let selected = arbiter.submit(
            candidate(
                language: .english,
                confidence: 0.4,
                start: 1.05,
                end: 1.05
            )
        )

        // Then: 長さ0でも開始時刻が近ければ同一発話として比較する
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.startTime, 1.0)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testZeroDurationRangesFarApartStayInSeparateBuckets() {
        // Given: 長さ0の日本語点区間
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                language: .japanese,
                confidence: 0.9,
                start: 1.0,
                end: 1.0
            )
        )

        // When: 開始が0.1秒以上離れた英語点区間が届く
        let selected = arbiter.submit(
            candidate(
                language: .english,
                confidence: 0.95,
                start: 1.15,
                end: 1.15
            )
        )

        // Then: 重なりも近接開始もない別発話として比較しない
        XCTAssertNil(selected)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertEqual(arbiter.pendingRangeCount, 2)
    }
}

private func candidate(
    language: SpokenLanguage,
    confidence: Double,
    start: Double,
    end: Double
) -> SpeechRecognitionCandidate {
    SpeechRecognitionCandidate(
        text: language == .japanese ? "テストです" : "This is a test",
        language: language,
        confidence: confidence,
        isFinal: false,
        startTime: start,
        endTime: end
    )
}
