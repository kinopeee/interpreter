import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterEmptyVolatileSelectionTests: XCTestCase {
    func testCounterpartEmptyVolatileDoesNotUnlockImmediateSelection() {
        // Given: 日本語レーンの暫定候補だけがある判定器
        var arbiter = BilingualSpeechArbiter()
        let japanese = arbiter.submit(
            candidate(language: .japanese, confidence: 0.9)
        )

        // When: 対向レーンから空のvolatileだけが届く
        let emptyEnglish = arbiter.submit(
            candidate(
                text: "",
                language: .english,
                confidence: 0,
                isFinal: false
            )
        )

        // Then: 空finalと違って即時レーン固定せず、日本語候補をpendingに残す
        XCTAssertNil(japanese)
        XCTAssertNil(emptyEnglish)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertTrue(arbiter.hasPendingCandidates)
        XCTAssertEqual(arbiter.pendingRangeCount, 1)
    }

    func testSelectBestAvailableStillLocksAfterCounterpartEmptyVolatile() {
        // Given: 日本語候補の後に対向レーンの空volatileだけが届いた判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))
        _ = arbiter.submit(
            candidate(
                text: "",
                language: .english,
                confidence: 0,
                isFinal: false
            )
        )

        // When: 対向レーン待ちの期限後に最良候補を選ぶ
        let selected = arbiter.selectBestAvailable()

        // Then: 空volatileで候補を消さず、期限後は日本語レーンを欠落させない
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testLockedLaneIgnoresOppositeEmptyVolatile() {
        // Given: 日本語レーンを選択済みの判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))

        // When: 固定中に対向レーンの空volatileが届く
        let ignored = arbiter.submit(
            candidate(
                text: "",
                language: .english,
                confidence: 0,
                isFinal: false
            )
        )

        // Then: 対向レーンの空文字でロックも表示も動かさない
        XCTAssertNil(ignored)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
        XCTAssertTrue(arbiter.hasPendingCandidates)
    }
}

private func candidate(
    text: String? = nil,
    language: SpokenLanguage,
    confidence: Double,
    isFinal: Bool = false
) -> SpeechRecognitionCandidate {
    SpeechRecognitionCandidate(
        text: text ?? (language == .japanese ? "テストです" : "This is a test"),
        language: language,
        confidence: confidence,
        isFinal: isFinal,
        startTime: 0,
        endTime: 1
    )
}
