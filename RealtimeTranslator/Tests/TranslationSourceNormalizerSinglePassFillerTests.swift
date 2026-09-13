import XCTest
@testable import RealtimeTranslator

final class TranslationSourceNormalizerSinglePassFillerTests: XCTestCase {
    func testDoesNotStripJapaneseFillerInTheMiddleOfASentence() {
        // Given: 文頭ではなく文中にだけフィラーがある日本語
        let source = "今日はえーと晴れです"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: 文中フィラーは翻訳器入力から落とさない
        XCTAssertEqual(normalized, "今日はえーと晴れです。")
    }

    func testStripsOnlyTheFirstLeadingJapaneseFiller() {
        // Given: 文頭フィラーが連続している日本語
        let source = "えーと、えっと、今日は晴れです"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: 先頭の1件だけ除去し、残りのフィラーは本文として残す
        XCTAssertEqual(normalized, "えっと、今日は晴れです。")
    }

    func testDoesNotStripEnglishFillerInTheMiddleOfASentence() {
        // Given: 文中にだけフィラーがある英文
        let source = "I think um we should go"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 文中のumは翻訳器入力から落とさない
        XCTAssertEqual(normalized, "I think um we should go.")
    }

    func testStripsOnlyTheFirstLeadingEnglishFiller() {
        // Given: you knowの後に別のフィラーが続く英文
        let source = "You know, um, I think so"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 先頭のyou knowだけ除去し、残りのumは本文として残す
        XCTAssertEqual(normalized, "um, I think so.")
    }
}
