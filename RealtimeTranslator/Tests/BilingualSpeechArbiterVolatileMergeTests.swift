import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterVolatileMergeTests: XCTestCase {
    func testMergedSameLanguageVolatilesPreferLaterEndTime() {
        // Given: 重なり不足で分かれた同一日本語レーンの2つの暫定バケット
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "短い暫定",
                language: .japanese,
                confidence: 0.7,
                start: 0,
                end: 0.3
            )
        )
        _ = arbiter.submit(
            candidate(
                text: "長くなった暫定",
                language: .japanese,
                confidence: 0.7,
                start: 0.25,
                end: 0.55
            )
        )
        XCTAssertEqual(arbiter.pendingRangeCount, 2)
        XCTAssertNil(arbiter.activeLanguage)

        // When: 両方に重なる英語候補でバケットが統合される
        let selected = arbiter.submit(
            candidate(
                text: "bridge",
                language: .english,
                confidence: 0.2,
                start: 0.1,
                end: 0.5
            )
        )

        // Then: 同一レーンの暫定同士では終了時刻が遅い方の原文を採用する
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "長くなった暫定")
        XCTAssertFalse(selected?.isFinal == true)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
        XCTAssertEqual(arbiter.pendingRangeCount, 1)
    }

    func testLockedRangeGrowthMergesPendingBucketWithoutUnlocking() {
        // Given: 先頭区間で日本語レーンを固定し、次区間の日本語候補を待機している判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(language: .english, confidence: 0.4, start: 0, end: 1)
        )
        let locked = arbiter.submit(
            candidate(language: .japanese, confidence: 0.9, start: 0, end: 1)
        )
        let queued = arbiter.submit(
            candidate(
                text: "次の発話",
                language: .japanese,
                confidence: 0.8,
                start: 1.5,
                end: 2.5
            )
        )
        XCTAssertEqual(locked?.language, .japanese)
        XCTAssertNil(queued)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
        XCTAssertEqual(arbiter.pendingRangeCount, 2)

        // When: 固定中の日本語認識が次区間と重なるまで伸びる
        let continued = arbiter.submit(
            candidate(
                text: "テストです続き",
                language: .japanese,
                confidence: 0.91,
                start: 0,
                end: 2
            )
        )
        let opposite = arbiter.submit(
            candidate(
                text: "should stay ignored",
                language: .english,
                confidence: 0.99,
                start: 0,
                end: 2
            )
        )

        // Then: 次区間を別発話として確定せず、日本語レーン固定と成長中の原文を維持する
        XCTAssertEqual(continued?.language, .japanese)
        XCTAssertEqual(continued?.text, "テストです続き")
        XCTAssertNil(opposite)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
        XCTAssertEqual(arbiter.pendingRangeCount, 1)
    }

    func testEmptyVolatileThenContinuationKeepsLockedLane() {
        // Given: 日本語レーンを固定し、途中で空のvolatile撤回が届いた判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))
        _ = arbiter.submit(
            candidate(
                text: "",
                language: .japanese,
                confidence: 0,
                isFinal: false
            )
        )
        XCTAssertEqual(arbiter.activeLanguage, .japanese)

        // When: 同じ日本語レーンが続き、対向の高信頼度英語も届く
        let resumed = arbiter.submit(
            candidate(
                text: "テストです続き",
                language: .japanese,
                confidence: 0.88
            )
        )
        let opposite = arbiter.submit(
            candidate(
                text: "This is a test",
                language: .english,
                confidence: 0.99
            )
        )

        // Then: 空volatileではロックを解かず、対向レーンへ往復しない
        XCTAssertEqual(resumed?.language, .japanese)
        XCTAssertEqual(resumed?.text, "テストです続き")
        XCTAssertNil(opposite)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
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
