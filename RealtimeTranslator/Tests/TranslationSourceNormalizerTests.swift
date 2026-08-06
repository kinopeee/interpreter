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

    func testRemovesBoundedAmbiguousJapaneseFillers() {
        // Given: 読点付きの曖昧フィラー(あの/その/まあ)
        let samples = [
            ("あの、今日は晴れです", "今日は晴れです。"),
            ("その、大丈夫です", "大丈夫です。"),
            ("まあ、大丈夫です", "大丈夫です。"),
        ]

        // When/Then: 区切りがあるときだけフィラー除去する
        for (source, expected) in samples {
            let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
                source,
                language: .japanese
            )
            XCTAssertEqual(normalized, expected)
        }
    }

    func testDoesNotStripJapaneseContentWordsThatShareFillerPrefixes() {
        // Given: 指示語・畳語として文頭に来る「あの/その/まあ」
        let samples = [
            ("あの人が来ました", "あの人が来ました。"),
            ("その通りです", "その通りです。"),
            ("まあまあです", "まあまあです。"),
        ]

        // When/Then: 本文の接頭辞を削らず句読点だけ補う
        for (source, expected) in samples {
            let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
                source,
                language: .japanese
            )
            XCTAssertEqual(normalized, expected)
        }
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
