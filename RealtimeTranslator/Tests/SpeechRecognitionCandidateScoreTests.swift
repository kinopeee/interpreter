import XCTest
@testable import RealtimeTranslator

final class SpeechRecognitionCandidateScoreTests: XCTestCase {
    func testMatchingJapaneseScriptAddsBonus() {
        // Given: 日本語文字を含む日本語レーンの候補
        let candidate = SpeechRecognitionCandidate(
            text: "こんにちは",
            language: .japanese,
            confidence: 0.80,
            isFinal: false,
            startTime: 0,
            endTime: 1
        )

        // When: レーン選択スコアを算出する
        // Then: 文字種一致の加点0.1を信頼度へ足す
        XCTAssertEqual(candidate.score, 0.90, accuracy: 0.0001)
        XCTAssertFalse(candidate.isAmbiguousLatinOnly)
    }

    func testMismatchedJapaneseScriptAppliesPenalty() {
        // Given: 日本語文字なのに英語レーンへ出た候補
        let candidate = SpeechRecognitionCandidate(
            text: "こんにちは",
            language: .english,
            confidence: 0.80,
            isFinal: false,
            startTime: 0,
            endTime: 1
        )

        // When: レーン選択スコアを算出する
        // Then: 不一致ペナルティ-0.15を適用し、加点より大きく減点する
        XCTAssertEqual(candidate.score, 0.65, accuracy: 0.0001)
    }

    func testMatchingEnglishScriptAddsBonus() {
        // Given: 複数Latin語を含む英語レーンの候補
        let candidate = SpeechRecognitionCandidate(
            text: "hello there",
            language: .english,
            confidence: 0.80,
            isFinal: false,
            startTime: 0,
            endTime: 1
        )

        // When: レーン選択スコアを算出する
        // Then: 英語文字種の一致加点を足す
        XCTAssertEqual(candidate.score, 0.90, accuracy: 0.0001)
        XCTAssertFalse(candidate.isAmbiguousLatinOnly)
    }

    func testAmbiguousLatinAndNumericEvidenceDoNotAdjustScore() {
        // Given: Latin一語と数字だけの候補
        let ambiguous = SpeechRecognitionCandidate(
            text: "Cursor",
            language: .english,
            confidence: 0.80,
            isFinal: false,
            startTime: 0,
            endTime: 1
        )
        let numeric = SpeechRecognitionCandidate(
            text: "1234",
            language: .japanese,
            confidence: 0.80,
            isFinal: false,
            startTime: 0,
            endTime: 1
        )

        // When: それぞれのスコアを算出する
        // Then: 曖昧Latinと無言語は加点も減点もしない
        XCTAssertEqual(ambiguous.score, 0.80, accuracy: 0.0001)
        XCTAssertTrue(ambiguous.isAmbiguousLatinOnly)
        XCTAssertEqual(numeric.score, 0.80, accuracy: 0.0001)
        XCTAssertFalse(numeric.isAmbiguousLatinOnly)
    }
}
