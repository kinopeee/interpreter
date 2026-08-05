import XCTest
@testable import RealtimeTranslator

final class SubtitleTailClipperTests: XCTestCase {
    func testShortJapanesePassesThrough() {
        // Given: 上限以下の日本語
        let text = "短い日本語の字幕です"

        // When: clipする
        let clipped = SubtitleTailClipper.clip(text)

        // Then: そのまま返す
        XCTAssertEqual(clipped, text)
    }

    func testShortEnglishPassesThrough() {
        // Given: 上限以下の英語
        let text = "Short English subtitle"

        // When: clipする
        let clipped = SubtitleTailClipper.clip(text)

        // Then: そのまま返す
        XCTAssertEqual(clipped, text)
    }

    func testLongJapaneseKeepsTailWithEllipsis() {
        // Given: 60字を超える日本語
        let text = String(repeating: "あ", count: 80)

        // When: clipする
        let clipped = SubtitleTailClipper.clip(text)

        // Then: 末尾60字＋「…」
        XCTAssertTrue(clipped.hasPrefix(SubtitleTailClipper.ellipsis))
        XCTAssertEqual(
            clipped.dropFirst(SubtitleTailClipper.ellipsis.count).count,
            SubtitleTailClipper.japaneseCharacterLimit
        )
        XCTAssertTrue(clipped.hasSuffix(String(repeating: "あ", count: 60)))
    }

    func testLongEnglishKeepsTailOnWordBoundary() {
        // Given: 120字を超える英語（単語境界あり）
        let word = "abcdefghij "
        let text = String(repeating: word, count: 20) // 220文字

        // When: clipする
        let clipped = SubtitleTailClipper.clip(text)

        // Then: 「…」付きで単語境界から始まり、上限付近の長さになる
        XCTAssertTrue(clipped.hasPrefix(SubtitleTailClipper.ellipsis))
        let body = String(clipped.dropFirst(SubtitleTailClipper.ellipsis.count))
        XCTAssertFalse(body.isEmpty)
        XCTAssertLessThanOrEqual(body.count, SubtitleTailClipper.englishCharacterLimit)
        // 単語途中で始まっていない（空白の直後の完全な単語から）
        XCTAssertFalse(body.first?.isWhitespace == true)
        XCTAssertTrue(body.hasPrefix("abcdefghij"))
    }

    func testEmptyStringPassesThrough() {
        // Given: 空文字
        // When/Then: 空のまま
        XCTAssertEqual(SubtitleTailClipper.clip(""), "")
    }

    func testWhitespaceOnlyPassesThrough() {
        // Given: 空白のみ
        let text = "   \n\t  "

        // When: clipする
        let clipped = SubtitleTailClipper.clip(text)

        // Then: 入力をそのまま返す（表示側の空判定を壊さない）
        XCTAssertEqual(clipped, text)
    }

    func testMixedTextWithCJKUsesJapaneseLimit() {
        // Given: 英字と日本語が混在しCJKを含む長い文
        let prefix = String(repeating: "a", count: 40)
        let japanese = String(repeating: "日", count: 40)
        let text = prefix + japanese

        // When: clipする
        let clipped = SubtitleTailClipper.clip(text)

        // Then: CJK含むので60字上限＋「…」
        XCTAssertTrue(clipped.hasPrefix(SubtitleTailClipper.ellipsis))
        XCTAssertEqual(
            clipped.dropFirst(SubtitleTailClipper.ellipsis.count).count,
            SubtitleTailClipper.japaneseCharacterLimit
        )
    }

    func testContainsCJKDetection() {
        // Given/When/Then: 日本語・漢字・英語の判定
        XCTAssertTrue(SubtitleTailClipper.containsCJK("こんにちは"))
        XCTAssertTrue(SubtitleTailClipper.containsCJK("漢字テスト"))
        XCTAssertTrue(SubtitleTailClipper.containsCJK("hello世界"))
        XCTAssertFalse(SubtitleTailClipper.containsCJK("Hello world"))
    }
}
