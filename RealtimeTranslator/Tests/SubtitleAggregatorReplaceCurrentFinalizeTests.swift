import XCTest
@testable import RealtimeTranslator

final class SubtitleAggregatorReplaceCurrentFinalizeTests: XCTestCase {
    func testReplaceCurrentDoesNotFinalizeUntilTickSeesCompletePair() {
        // Given: 句点付きの完全ペアをreplaceCurrentで載せた字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()

        // When: 確定可能なペアをcurrentへ置き、直後のsnapshotとtickを取る
        let replaced = aggregator.replaceCurrent(
            sourceText: "完了です。",
            translatedText: "Done.",
            isTranslationCurrent: true,
            canFinalize: true,
            now: now
        )
        let afterTick = aggregator.tick(now: now)

        // Then: 置換時点ではライブのままにし、tickで句点によるその場確定へ進む
        XCTAssertEqual(replaced.current.state, .live)
        XCTAssertEqual(afterTick.current.state, .finalized)
        XCTAssertEqual(afterTick.current.sourceText, "完了です。")
        XCTAssertEqual(afterTick.current.translatedText, "Done.")
    }

    func testReplaceCurrentWithStaleTranslationDoesNotFinalizeOnTick() {
        // Given: 旧訳文を残したまま新しい原文へ置き換えた字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.replaceCurrent(
            sourceText: "新しい原文です。",
            translatedText: "Old translation.",
            isTranslationCurrent: false,
            canFinalize: false,
            now: now
        )

        // When: 句点とアイドル時間の両方を満たすtickを行う
        let snapshot = aggregator.tick(now: now.addingTimeInterval(2))

        // Then: 更新待ちの旧訳ではその場確定しない
        XCTAssertEqual(snapshot.current.state, .live)
        XCTAssertEqual(snapshot.current.sourceText, "新しい原文です。")
        XCTAssertEqual(snapshot.current.translatedText, "Old translation.")
        XCTAssertFalse(snapshot.current.isTranslationCurrent)
        XCTAssertFalse(snapshot.current.canFinalize)
    }
}
