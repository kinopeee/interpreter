import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterDelayedSelectionTests: XCTestCase {
    func testSelectBestAvailableSelectsSingleJapaneseCandidate() {
        // Given: 対向レーンがまだ届いていない日本語候補だけを持つ判定器
        var arbiter = BilingualSpeechArbiter()
        let submitted = arbiter.submit(
            candidate(
                text: "今日は晴れです",
                language: .japanese,
                confidence: 0.8
            )
        )

        // When: 遅延選択の期限後に最善候補を選ぶ
        let selected = arbiter.selectBestAvailable()

        // Then: 対向待ちで字幕を止めず、日本語レーンを固定する
        XCTAssertNil(submitted)
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "今日は晴れです")
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testSelectBestAvailablePrefersEarlierPendingRange() {
        // Given: 重ならない2区間に、それぞれ片レーンだけの候補がある判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "後の発話です",
                language: .japanese,
                confidence: 0.9,
                start: 2,
                end: 3
            )
        )
        _ = arbiter.submit(
            candidate(
                text: "先の発話です",
                language: .japanese,
                confidence: 0.7,
                start: 0,
                end: 1
            )
        )

        // When: 遅延選択で未固定の候補から1件選ぶ
        let selected = arbiter.selectBestAvailable()

        // Then: 開始時刻が早い区間を先に固定し、後続区間は未選択のまま残す
        XCTAssertEqual(selected?.text, "先の発話です")
        XCTAssertEqual(selected?.startTime, 0)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
        XCTAssertEqual(arbiter.pendingRangeCount, 2)
    }

    private func candidate(
        text: String,
        language: SpokenLanguage,
        confidence: Double,
        start: Double = 0,
        end: Double? = nil
    ) -> SpeechRecognitionCandidate {
        SpeechRecognitionCandidate(
            text: text,
            language: language,
            confidence: confidence,
            isFinal: false,
            startTime: start,
            endTime: end ?? start + 1
        )
    }
}
