import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterTests: XCTestCase {
    func testWaitsForBothLanguageCandidatesBeforeChoosing() {
        // Given: 言語が未確定の判定器
        var arbiter = BilingualSpeechArbiter()
        let japanese = candidate(language: .japanese, confidence: 0.8)

        // When: 日本語レーンだけが先に届く
        let selected = arbiter.submit(japanese)

        // Then: 早すぎる言語確定を行わない
        XCTAssertNil(selected)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertTrue(arbiter.hasPendingCandidates)
    }

    func testKeepsSelectedLanguageUntilFinalResult() {
        // Given: 日本語レーンの信頼度が高い同一区間の候補
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.45))
        let selected = arbiter.submit(candidate(language: .japanese, confidence: 0.9))

        // When: 選択後に英語レーンの更新が届く
        let ignored = arbiter.submit(candidate(language: .english, confidence: 0.99))

        // Then: 文中では日本語レーンを維持して表示の往復を防ぐ
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
        XCTAssertNil(ignored)
    }

    func testCanChooseOppositeLanguageAfterFinalResult() {
        // Given: 日本語レーンを選択済みの判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))

        // When: 日本語の確定結果後、次区間で英語候補を受け取る
        let finalized = arbiter.submit(
            candidate(language: .japanese, confidence: 0.92, isFinal: true)
        )
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.3, start: 2))
        let next = arbiter.submit(candidate(language: .english, confidence: 0.95, start: 2))

        // Then: ロックを解除して次の英語区間を選択できる
        XCTAssertTrue(finalized?.isFinal == true)
        XCTAssertEqual(next?.language, .english)
        XCTAssertEqual(arbiter.activeLanguage, .english)
    }

    func testIgnoresLateOppositeFinalForFinalizedRange() {
        // Given: 同一区間で日本語レーンを選択し、確定結果まで受信した判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))
        let finalized = arbiter.submit(
            candidate(language: .japanese, confidence: 0.92, isFinal: true)
        )

        // When: 同じ音声範囲の英語レーン確定結果が遅れて届く
        let lateOpposite = arbiter.submit(
            candidate(language: .english, confidence: 0.99, isFinal: true)
        )

        // Then: 同じ音声を別発話として再選択しない
        XCTAssertTrue(finalized?.isFinal == true)
        XCTAssertNil(lateOpposite)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertFalse(arbiter.hasPendingCandidates)
    }

    private func candidate(
        language: SpokenLanguage,
        confidence: Double,
        isFinal: Bool = false,
        start: Double = 0
    ) -> SpeechRecognitionCandidate {
        SpeechRecognitionCandidate(
            text: language == .japanese ? "テストです" : "This is a test",
            language: language,
            confidence: confidence,
            isFinal: isFinal,
            startTime: start,
            endTime: start + 1
        )
    }
}
