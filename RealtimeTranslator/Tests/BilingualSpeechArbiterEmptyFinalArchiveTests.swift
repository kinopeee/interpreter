import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterEmptyFinalArchiveTests: XCTestCase {
    func testBothLaneEmptyFinalsTombstoneTheRange() {
        // Given: 同一区間に日本語の暫定結果だけがある判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "テスト",
                language: .japanese,
                confidence: 0.9,
                start: 0,
                end: 1
            )
        )

        // When: 英語空finalのあと、日本語も空finalへ置き換わる
        _ = arbiter.submit(
            candidate(
                text: "",
                language: .english,
                confidence: 0,
                isFinal: true,
                start: 0,
                end: 1
            )
        )
        _ = arbiter.submit(
            candidate(
                text: "",
                language: .japanese,
                confidence: 0,
                isFinal: true,
                start: 0,
                end: 1
            )
        )

        // Then: 取り消した区間を確定済みとして残し、重なる遅延候補を復活させない
        XCTAssertFalse(arbiter.hasPendingCandidates)
        XCTAssertEqual(arbiter.pendingRangeCount, 0)
        XCTAssertNil(
            arbiter.submit(
                candidate(
                    text: "遅延",
                    language: .japanese,
                    confidence: 0.9,
                    start: 0.2,
                    end: 0.8
                )
            )
        )
        XCTAssertNil(arbiter.activeLanguage)
    }

    func testSingleLaneEmptyFinalDoesNotTombstoneUnrelatedLaterRange() {
        // Given: 片方レーンの空finalだけで取り消した区間
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "",
                language: .japanese,
                confidence: 0,
                isFinal: true,
                start: 0,
                end: 1
            )
        )

        // When: 重ならない次区間の日本語候補が届く
        let next = arbiter.submit(
            candidate(
                text: "次の発話",
                language: .japanese,
                confidence: 0.9,
                start: 2,
                end: 3
            )
        )

        // Then: 片レーン取消は別発話を確定済み扱いにしない
        XCTAssertNil(next)
        XCTAssertTrue(arbiter.hasPendingCandidates)
        XCTAssertEqual(arbiter.pendingRangeCount, 1)
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
