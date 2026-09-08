import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterMergeTests: XCTestCase {
    func testTransitiveOverlapMergesDisconnectedRanges() {
        // Given: 直接は重ならない先行日本語区間と後続英語区間
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(text: "こんにちは", language: .japanese, confidence: 0.9, start: 0, end: 1)
        )
        _ = arbiter.submit(
            candidate(
                text: "hello there",
                language: .english,
                confidence: 0.4,
                start: 1.2,
                end: 2.2
            )
        )
        XCTAssertEqual(arbiter.pendingRangeCount, 2)

        // When: 両方に50%重なる中間候補が届く
        let selected = arbiter.submit(
            candidate(
                text: "hello",
                language: .english,
                confidence: 0.35,
                start: 0.5,
                end: 1.7
            )
        )

        // Then: 推移的に1区間へ統合し、日英を比較して日本語を選ぶ
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "こんにちは")
        XCTAssertEqual(arbiter.pendingRangeCount, 1)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testResetClearsLaneLockAndPendingBuckets() {
        // Given: 日本語レーンを固定中の判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))
        XCTAssertEqual(arbiter.activeLanguage, .japanese)

        // When: 判定器をリセットして英語候補だけを入れる
        arbiter.reset()
        let selected = arbiter.submit(candidate(language: .english, confidence: 0.95))

        // Then: 旧ロックを残さず、対向待ちの未確定状態へ戻る
        XCTAssertNil(selected)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertTrue(arbiter.hasPendingCandidates)
    }

    func testExactHalfOverlapPairsOppositeLanes() {
        // Given: 短い方の50%ちょうどが重なる日英区間
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(language: .japanese, confidence: 0.9, start: 0, end: 1)
        )

        // When: 開始が0.5秒ずれた英語候補が届く
        let selected = arbiter.submit(
            candidate(language: .english, confidence: 0.4, start: 0.5, end: 1.5)
        )

        // Then: 閾値ちょうどを同一発話として比較する
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testExactNearStartToleranceDoesNotPairNonOverlappingRanges() {
        // Given: 開始差が0.1秒ちょうどで、時間範囲は重ならない短い2区間
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(language: .japanese, confidence: 0.9, start: 0, end: 0.05)
        )

        // When: 開始差が許容の境界値である英語候補が届く
        let selected = arbiter.submit(
            candidate(language: .english, confidence: 0.95, start: 0.1, end: 0.15)
        )

        // Then: 0.1秒未満の近接だけを同一発話とみなし、境界値は別区間にする
        XCTAssertNil(selected)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertEqual(arbiter.pendingRangeCount, 2)
    }

    func testNumericEvidenceDoesNotBeatJapaneseCandidate() {
        // Given: 高信頼度だが言語証拠のない数字列と、日本語文字を含む低信頼度候補
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(text: "12345", language: .english, confidence: 0.99)
        )

        // When: 対向の日本語候補が届く
        let selected = arbiter.submit(
            candidate(text: "テストです", language: .japanese, confidence: 0.4)
        )

        // Then: 数字だけのレーンを勝者にせず、日本語を選ぶ
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "テストです")
    }

    private func candidate(
        text: String? = nil,
        language: SpokenLanguage,
        confidence: Double,
        isFinal: Bool = false,
        start: Double = 0,
        end: Double? = nil
    ) -> SpeechRecognitionCandidate {
        SpeechRecognitionCandidate(
            text: text ?? (language == .japanese ? "テストです" : "This is a test"),
            language: language,
            confidence: confidence,
            isFinal: isFinal,
            startTime: start,
            endTime: end ?? start + 1
        )
    }
}
