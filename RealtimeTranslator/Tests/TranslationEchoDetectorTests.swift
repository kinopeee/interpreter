import XCTest
@testable import RealtimeTranslator

final class TranslationEchoDetectorTests: XCTestCase {
    func testDetectsEchoIgnoringTerminalPunctuationAndCase() {
        // Given: 認識された英文と、句点と大文字化だけが違う訳文
        let source = "is on of comthing"
        let translated = "Is on of comthing."

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 未翻訳echoとして検出する
        XCTAssertTrue(isEcho)
    }

    func testDetectsJapaneseEchoWithAppendedPeriod() {
        // Given: 日本語原文と、正規化で付いた句点だけが違う訳文
        let source = "文A"
        let translated = "文A。"

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 未翻訳echoとして検出する
        XCTAssertTrue(isEcho)
    }

    func testRealTranslationIsNotEcho() {
        // Given: 実際に言語が変わっている原文と訳文のペア
        let source = "こんにちは"
        let translated = "Hello."

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: echoとして扱わない
        XCTAssertFalse(isEcho)
    }

    func testEmptyTranslatedIsNotEcho() {
        // Given: 訳文が空のペア
        let source = "こんにちは"
        let translated = ""

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: echoとして扱わない(空訳文は別経路で弾かれる)
        XCTAssertFalse(isEcho)
    }

    func testPunctuationOnlyPairIsNotEcho() {
        // Given: 句読点だけで実質空になる原文と訳文
        let source = "。"
        let translated = "。"

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 正規化後が空のペアはechoとして扱わない
        XCTAssertFalse(isEcho)
    }

    func testDetectsEchoIgnoringSurroundingWhitespace() {
        // Given: 前後空白と句点だけが違う未翻訳ペア
        let source = "  broken speech  "
        let translated = "broken speech."

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 空白差を無視して未翻訳echoとして検出する
        XCTAssertTrue(isEcho)
    }
}
