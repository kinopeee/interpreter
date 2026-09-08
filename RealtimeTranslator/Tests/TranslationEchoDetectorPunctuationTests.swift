import XCTest
@testable import RealtimeTranslator

final class TranslationEchoDetectorPunctuationTests: XCTestCase {
    func testDetectsEchoWithRepeatedTrailingPunctuation() {
        // Given: 原文と、終端句読点だけが複数個多い訳文
        let source = "hello"
        let translated = "hello!!"

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 重ねた終端記号を未翻訳echoとして検出する
        XCTAssertTrue(isEcho)
    }

    func testDetectsEchoWithMixedJapaneseAndEnglishPeriods() {
        // Given: 原文と、全角・半角の句点が混ざった訳文
        let source = "文A"
        let translated = "文A。."

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 終端記号の種類が違っても未翻訳echoとして検出する
        XCTAssertTrue(isEcho)
    }

    func testDoesNotTreatWhitespaceOnlyTranslationAsEcho() {
        // Given: 原文はあるが訳文が空白だけ
        let source = "こんにちは"
        let translated = "   "

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 空訳文経路へ倒し、echo確定しない
        XCTAssertFalse(isEcho)
    }
}
