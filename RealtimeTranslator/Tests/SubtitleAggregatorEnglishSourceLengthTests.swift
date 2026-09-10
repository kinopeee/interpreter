import XCTest
@testable import RealtimeTranslator

final class SubtitleAggregatorEnglishSourceLengthTests: XCTestCase {
    func testEnglishSourceUsesJapaneseLengthCap() {
        // Given: 原文は常に日本語側の文字数上限で切る集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        let englishSource = String(repeating: "a", count: 61)

        // When: 61文字の英語原文と短い訳文をペアにする
        _ = aggregator.appendSource(englishSource, now: now)
        let snapshot = aggregator.appendTranslation("短い訳", now: now)

        // Then: 英語原文でも60文字超でその場確定し、字幕ブロックを伸ばしすぎない
        XCTAssertEqual(snapshot.current.sourceText, englishSource)
        XCTAssertEqual(snapshot.current.translatedText, "短い訳")
        XCTAssertEqual(snapshot.current.state, .finalized)
    }

    func testIdeographicFullStopOnTranslationFinalizesPair() {
        // Given: 原文はあるが訳文の終端が全角ピリオドのペア
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("今日は会議です", now: now)

        // When: 終端が「．」の訳文を追加する
        let snapshot = aggregator.appendTranslation("Today is the meeting．", now: now)

        // Then: 半角ピリオドと同じ終端記号としてその場確定する
        XCTAssertEqual(snapshot.current.state, .finalized)
        XCTAssertEqual(snapshot.current.translatedText, "Today is the meeting．")
    }

    func testForceFinalizeOnAlreadyFinalizedPairKeepsPair() {
        // Given: すでにその場確定している原文・訳文ペア
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.finalizePair(
            sourceText: "完了。",
            translatedText: "Done.",
            clearCurrent: true,
            now: now
        )

        // When: 停止時の強制確定をもう一度かける
        let snapshot = aggregator.forceFinalize(now: now.addingTimeInterval(1))

        // Then: 確定ペアを空にせずcurrentへ残す
        XCTAssertEqual(snapshot.current.sourceText, "完了。")
        XCTAssertEqual(snapshot.current.translatedText, "Done.")
        XCTAssertEqual(snapshot.current.state, .finalized)
    }
}
