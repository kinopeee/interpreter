import XCTest
@testable import RealtimeTranslator

final class TranslationSourceNormalizerBoundaryTests: XCTestCase {
    func testEnglishFillerDoesNotStripUmbrella() {
        // Given: 文頭フィラー "um" と接頭辞が同じ内容語
        let source = "umbrella is open"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 単語境界のない "umbrella" を切断しない
        XCTAssertEqual(normalized, "umbrella is open.")
    }

    func testEnglishFillerDoesNotStripLikewise() {
        // Given: 文頭フィラー "like" と接頭辞が同じ内容語
        let source = "likewise we agree"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: "like" フィラーとして "likewise" を落とさない
        XCTAssertEqual(normalized, "likewise we agree.")
    }

    func testEnglishFillerDoesNotStripAhead() {
        // Given: 文頭フィラー "ah" と接頭辞が同じ内容語
        let source = "ahead of schedule"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: "ah" フィラーとして "ahead" を切断しない
        XCTAssertEqual(normalized, "ahead of schedule.")
    }

    func testKeepsJapaneseQuestionAndExclamationMarks() {
        // Given: 終端が全角疑問符と感嘆符の日本語文
        let question = "終わりですか？"
        let exclamation = "すごい！"

        // When: それぞれ正規化する
        let normalizedQuestion = TranslationSourceNormalizer.normalizeForFinalTranslation(
            question,
            language: .japanese
        )
        let normalizedExclamation = TranslationSourceNormalizer.normalizeForFinalTranslation(
            exclamation,
            language: .japanese
        )

        // Then: 既存の終端記号を「。」で置き換えない
        XCTAssertEqual(normalizedQuestion, "終わりですか？")
        XCTAssertEqual(normalizedExclamation, "すごい！")
    }

    func testEnglishQuestionMarkIsTerminal() {
        // Given: 終端が疑問符の英文
        let source = "Are you ready?"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 追加のピリオドを重ねない
        XCTAssertEqual(normalized, "Are you ready?")
    }
}
