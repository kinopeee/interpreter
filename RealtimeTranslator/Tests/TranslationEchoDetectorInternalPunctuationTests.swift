import XCTest
@testable import RealtimeTranslator

final class TranslationEchoDetectorInternalPunctuationTests: XCTestCase {
    func testInternalPeriodKeepsPairFromBeingEcho() {
        // Given: 文中のピリオドの有無だけが違う原文と訳文
        let source = "Wait. Now"
        let translated = "Wait Now"

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 終端以外の句読点は意味の一部として残し、未翻訳echoにしない
        XCTAssertFalse(isEcho)
    }

    func testLeadingPunctuationKeepsPairFromBeingEcho() {
        // Given: 先頭の感嘆符だけが違う原文と訳文
        let source = "!OK"
        let translated = "OK"

        // When: echo判定する
        let isEcho = TranslationEchoDetector.isEcho(
            source: source,
            translated: translated
        )

        // Then: 先頭記号は剥がさず、別文として扱う
        XCTAssertFalse(isEcho)
    }
}
