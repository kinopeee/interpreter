import XCTest
@testable import RealtimeTranslator

final class SubtitleAggregatorIdleBoundaryTests: XCTestCase {
    func testFinalizesPairAtExactIdleInterval() {
        // Given: アイドル確定時間が1秒の字幕集約器と完了済みの原文・訳文ペア
        var config = SubtitleAggregatorConfig()
        config.idleFinalizeInterval = 1.0
        let aggregator = SubtitleAggregator(config: config)
        let start = Date()
        _ = aggregator.appendSource("途中の文", now: start)
        _ = aggregator.appendTranslation("An unfinished sentence", now: start)

        // When: 1秒ちょうどと、その直前にtickする
        let before = aggregator.tick(now: start.addingTimeInterval(0.999))
        let exact = aggregator.tick(now: start.addingTimeInterval(1.0))

        // Then: 閾値未満はライブ、`>=`の1秒ちょうどでその場確定する
        XCTAssertEqual(before.current.state, .live)
        XCTAssertEqual(exact.current.sourceText, "途中の文")
        XCTAssertEqual(exact.current.translatedText, "An unfinished sentence")
        XCTAssertEqual(exact.current.state, .finalized)
    }

    func testExactIdleIntervalDoesNotFinalizeSourceOnly() {
        // Given: 訳文がまだない原文だけの字幕集約器
        var config = SubtitleAggregatorConfig()
        config.idleFinalizeInterval = 1.0
        let aggregator = SubtitleAggregator(config: config)
        let start = Date()
        _ = aggregator.appendSource("途中の文", now: start)

        // When: アイドル閾値ちょうどでtickする
        let snapshot = aggregator.tick(now: start.addingTimeInterval(1.0))

        // Then: 原文だけを確定せず、ライブのまま残す
        XCTAssertEqual(snapshot.current.sourceText, "途中の文")
        XCTAssertTrue(snapshot.current.translatedText.isEmpty)
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testTrailingWhitespaceDoesNotBlockTranslationPunctuationFinalize() {
        // Given: 句点付き原文を保持する字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("今日はCursorです。", now: now)

        // When: 終端記号のあとに空白だけが付いた訳文が届く
        let snapshot = aggregator.appendTranslation("This is Cursor.  \n", now: now)

        // Then: 末尾空白で句点判定を外さず、ペアをその場確定する
        XCTAssertEqual(snapshot.current.sourceText, "今日はCursorです。")
        XCTAssertEqual(snapshot.current.translatedText, "This is Cursor.  \n")
        XCTAssertEqual(snapshot.current.state, .finalized)
    }

    func testFinalizePairRejectsWhitespaceOnlySource() {
        // Given: ライブ原文を表示中の字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("既存の原文", now: now)

        // When: 空白だけの原文と訳文で確定しようとする
        let snapshot = aggregator.finalizePair(
            sourceText: "   ",
            translatedText: "Hello.",
            clearCurrent: true,
            now: now
        )

        // Then: 不完全ペアを確定せず、既存のライブ原文を残す
        XCTAssertEqual(snapshot.current.sourceText, "既存の原文")
        XCTAssertEqual(snapshot.current.state, .live)
        XCTAssertTrue(snapshot.current.translatedText.isEmpty)
    }
}
