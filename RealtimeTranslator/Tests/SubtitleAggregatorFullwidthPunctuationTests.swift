import XCTest
@testable import RealtimeTranslator

final class SubtitleAggregatorFullwidthPunctuationTests: XCTestCase {
    func testFullwidthQuestionMarkFinalizesPair() {
        // Given: 句点のない原文と、全角疑問符で終わる訳文
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("今日はCursorですか", now: now)

        // When: Apple Translationが返しやすい全角「？」で訳文が完了する
        let snapshot = aggregator.appendTranslation(
            "Is it Cursor？",
            now: now
        )

        // Then: ASCIIの?だけでなく全角疑問符でもペアをその場確定する
        XCTAssertEqual(snapshot.current.sourceText, "今日はCursorですか")
        XCTAssertEqual(snapshot.current.translatedText, "Is it Cursor？")
        XCTAssertEqual(snapshot.current.state, .finalized)
    }

    func testFullwidthExclamationMarkFinalizesPair() {
        // Given: 句点のない原文と、全角感嘆符で終わる訳文
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("すごい", now: now)

        // When: 全角「！」で終わる訳文を追加する
        let snapshot = aggregator.appendTranslation("Amazing！", now: now)

        // Then: 全角感嘆符を終端記号としてペアを確定する
        XCTAssertEqual(snapshot.current.sourceText, "すごい")
        XCTAssertEqual(snapshot.current.translatedText, "Amazing！")
        XCTAssertEqual(snapshot.current.state, .finalized)
    }
}
