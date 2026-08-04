import XCTest
@testable import RealtimeTranslator

final class TranslationSourceNormalizerTests: XCTestCase {
    func testAppendsJapanesePeriodWhenMissing() {
        // Given: 終端句読点のない日本語文
        let source = "こんにちは"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: 文末に「。」を付ける
        XCTAssertEqual(normalized, "こんにちは。")
    }

    func testAppendsEnglishPeriodWhenMissing() {
        // Given: 終端句読点のない英文
        let source = "Hello there"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 文末に「.」を付ける
        XCTAssertEqual(normalized, "Hello there.")
    }

    func testDoesNotDuplicateExistingTerminalPunctuation() {
        // Given: すでに終端句読点がある日英の文
        let japanese = "終わりです。"
        let english = "Done!"

        // When: それぞれ正規化する
        let normalizedJapanese = TranslationSourceNormalizer.normalizeForFinalTranslation(
            japanese,
            language: .japanese
        )
        let normalizedEnglish = TranslationSourceNormalizer.normalizeForFinalTranslation(
            english,
            language: .english
        )

        // Then: 句読点を重ねず元の終端を維持する
        XCTAssertEqual(normalizedJapanese, "終わりです。")
        XCTAssertEqual(normalizedEnglish, "Done!")
    }

    func testRemovesLeadingJapaneseFiller() {
        // Given: 文頭にフィラーと読点がある日本語文
        let source = "えーと、今日は晴れです"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: 文頭フィラーを除去し、句読点を補う
        XCTAssertEqual(normalized, "今日は晴れです。")
    }

    func testRemovesLeadingEnglishFiller() {
        // Given: 文頭にフィラーとカンマがある英文
        let source = "Um, I think so"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 文頭フィラーを除去し、句読点を補う
        XCTAssertEqual(normalized, "I think so.")
    }

    func testFallsBackWhenFillerRemovalEmptiesText() {
        // Given: フィラーだけの日本語入力
        let source = "えーと"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: 空文へせずトリム済み元テキストへフォールバックして句読点を付ける
        XCTAssertEqual(normalized, "えーと。")
    }

    func testEmptyInputRemainsEmpty() {
        // Given: 空白だけの入力
        let source = "   "

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: 空文字のまま返す
        XCTAssertEqual(normalized, "")
    }
}
