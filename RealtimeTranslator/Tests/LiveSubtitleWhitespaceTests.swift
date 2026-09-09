import XCTest
@testable import RealtimeTranslator

final class LiveSubtitleWhitespaceTests: XCTestCase {
    func testWhitespaceOnlyPairIsEmpty() {
        // Given: 空白と改行だけの原文・訳文
        let subtitle = LiveSubtitle(
            sourceText: "  \n",
            translatedText: "\t",
            lastUpdatedAt: Date(),
            state: .live
        )

        // When: 空判定する
        // Then: 表示対象がないものとして扱う
        XCTAssertTrue(subtitle.isEmpty)
    }

    func testVisibleSourcePreventsEmpty() {
        // Given: 空白に見えるが日本語文字を1字含む字幕
        let subtitle = LiveSubtitle(
            sourceText: " あ ",
            translatedText: "   ",
            lastUpdatedAt: Date(),
            state: .live
        )

        // When: 空判定する
        // Then: 原文が残っている間はスロットを空にしない
        XCTAssertFalse(subtitle.isEmpty)
    }
}
