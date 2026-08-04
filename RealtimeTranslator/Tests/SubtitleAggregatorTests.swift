import XCTest
@testable import RealtimeTranslator

final class SubtitleAggregatorTests: XCTestCase {
    func testAppendsSourceAndTranslationDeltas() {
        // Given: 空の字幕集約器
        let aggregator = SubtitleAggregator()

        // When: 原文と翻訳のdeltaを順に追加する
        _ = aggregator.appendSource("Hello")
        let snapshot = aggregator.appendTranslation("こんにちは")

        // Then: 同じライブ字幕ブロックへ原文と翻訳を保持する
        XCTAssertEqual(snapshot.current.sourceText, "Hello")
        XCTAssertEqual(snapshot.current.translatedText, "こんにちは")
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testSourcePunctuationWaitsForTranslation() {
        // Given: 翻訳がまだ届いていない字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()

        // When: 句点付き原文だけを追加してtickする
        _ = aggregator.appendSource("今日はCursorです。", now: now)
        let snapshot = aggregator.tick(now: now.addingTimeInterval(2))

        // Then: 原文だけを確定せず、翻訳待ちのライブブロックに残す
        XCTAssertEqual(snapshot.current.sourceText, "今日はCursorです。")
        XCTAssertEqual(snapshot.current.translatedText, "")
        XCTAssertNil(snapshot.previous)
    }

    func testFinalizesPairedSubtitleOnTranslationPunctuation() {
        // Given: 句点付き原文を保持する字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("今日はCursorです。", now: now)

        // When: 終端記号付き翻訳を追加する
        let snapshot = aggregator.appendTranslation("This is Cursor.", now: now)

        // Then: 原文と翻訳を同じ確定字幕として保持する
        XCTAssertTrue(snapshot.current.isEmpty)
        XCTAssertEqual(snapshot.previous?.sourceText, "今日はCursorです。")
        XCTAssertEqual(snapshot.previous?.translatedText, "This is Cursor.")
        XCTAssertEqual(snapshot.previous?.state, .finalized)
    }

    func testDoesNotFinalizePreservedTranslationDuringSourceUpdate() {
        // Given: 更新中の原文と、ひとつ前の表示を維持した訳文
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.replaceCurrent(
            sourceText: "今日は新しい話題について",
            translatedText: "Today.",
            isTranslationCurrent: false,
            canFinalize: false,
            now: now
        )

        // When: 通常の確定時間を超えてtickする
        let snapshot = aggregator.tick(now: now.addingTimeInterval(2))

        // Then: 旧訳文の句点やアイドル時間で新しい原文を誤確定しない
        XCTAssertEqual(snapshot.current.sourceText, "今日は新しい話題について")
        XCTAssertEqual(snapshot.current.translatedText, "Today.")
        XCTAssertFalse(snapshot.current.isTranslationCurrent)
        XCTAssertNil(snapshot.previous)
    }

    func testFinalizesPairAfterIdleInterval() {
        // Given: アイドル確定時間が1秒の字幕集約器と原文・翻訳ペア
        var config = SubtitleAggregatorConfig()
        config.idleFinalizeInterval = 1.0
        let aggregator = SubtitleAggregator(config: config)
        let start = Date()
        _ = aggregator.appendSource("途中の文", now: start)
        _ = aggregator.appendTranslation("An unfinished sentence", now: start)

        // When: 0.5秒後と1.1秒後にtickする
        let before = aggregator.tick(now: start.addingTimeInterval(0.5))
        let after = aggregator.tick(now: start.addingTimeInterval(1.1))

        // Then: 1秒未満ではライブ、1秒超過後はペアのまま確定する
        XCTAssertFalse(before.current.isEmpty)
        XCTAssertTrue(after.current.isEmpty)
        XCTAssertEqual(after.previous?.sourceText, "途中の文")
        XCTAssertEqual(after.previous?.translatedText, "An unfinished sentence")
    }

    func testPreviousFadesAfterHoldInterval() {
        // Given: 5秒保持・0.3秒フェードの字幕集約器と確定済みペア
        var config = SubtitleAggregatorConfig()
        config.previousHoldInterval = 5
        config.fadeDuration = 0.3
        let aggregator = SubtitleAggregator(config: config)
        let start = Date()
        _ = aggregator.replaceCurrent(sourceText: "完了。", translatedText: "Done.", now: start)
        _ = aggregator.tick(now: start)

        // When: フェード途中と完了後にtickする
        let midFade = aggregator.tick(now: start.addingTimeInterval(5.15))
        let gone = aggregator.tick(now: start.addingTimeInterval(5.4))

        // Then: フェード中は透明度が下がり、完了後は履歴が消える
        XCTAssertNotNil(midFade.previous)
        XCTAssertLessThan(midFade.previousOpacity, 1)
        XCTAssertNil(gone.previous)
    }

    func testFinalizePairWithClearCurrentKeepsPairInCurrentSlot() {
        // Given: 空の字幕集約器
        let aggregator = SubtitleAggregator()

        // When: 現在の発話に対応する確定ペアをclearCurrent付きで確定する
        let snapshot = aggregator.finalizePair(
            sourceText: "確定文",
            translatedText: "Finalized sentence",
            clearCurrent: true
        )

        // Then: previousへ移さず、currentスロットにその場確定で残す
        XCTAssertEqual(snapshot.current.sourceText, "確定文")
        XCTAssertEqual(snapshot.current.translatedText, "Finalized sentence")
        XCTAssertEqual(snapshot.current.state, .finalized)
        XCTAssertNil(snapshot.previous)
    }

    func testNextUtterancePromotesInPlacePairToPrevious() {
        // Given: currentスロットにその場確定ペアを保持する字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.finalizePair(
            sourceText: "確定文",
            translatedText: "Finalized sentence",
            clearCurrent: true,
            now: now
        )

        // When: 次の発話がcurrentへ入る
        let snapshot = aggregator.replaceCurrent(
            sourceText: "次の発話",
            translatedText: "",
            isTranslationCurrent: false,
            canFinalize: false,
            now: now.addingTimeInterval(1)
        )

        // Then: その場確定ペアをpreviousへ退避し、フル保持時間を与える
        XCTAssertEqual(snapshot.previous?.sourceText, "確定文")
        XCTAssertEqual(snapshot.previous?.translatedText, "Finalized sentence")
        XCTAssertEqual(snapshot.previousOpacity, 1)
        XCTAssertEqual(snapshot.current.sourceText, "次の発話")
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testInPlacePairExpiresToPreviousAfterHoldInterval() {
        // Given: 5秒保持・0.3秒フェード設定で、その場確定ペアを保持する字幕集約器
        var config = SubtitleAggregatorConfig()
        config.previousHoldInterval = 5
        config.fadeDuration = 0.3
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()
        _ = aggregator.finalizePair(
            sourceText: "確定文",
            translatedText: "Finalized sentence",
            clearCurrent: true,
            now: now
        )

        // When: 保持時間の手前と超過後にtickする
        let held = aggregator.tick(now: now.addingTimeInterval(4.9))
        let expired = aggregator.tick(now: now.addingTimeInterval(5.1))

        // Then: 保持中はその場に残し、超過後はpreviousへ退避して即フェードを開始する
        XCTAssertEqual(held.current.sourceText, "確定文")
        XCTAssertNil(held.previous)
        XCTAssertTrue(expired.current.isEmpty)
        XCTAssertEqual(expired.previous?.sourceText, "確定文")
        XCTAssertLessThan(expired.previousOpacity, 1)
    }

    func testForceFinalizeOnStop() {
        // Given: 録音停止前の原文・翻訳ペア
        let aggregator = SubtitleAggregator()
        _ = aggregator.replaceCurrent(
            sourceText: "Still speaking",
            translatedText: "まだ話しています"
        )

        // When: 強制確定する
        let snapshot = aggregator.forceFinalize()

        // Then: ペアを確定字幕へ移動する
        XCTAssertTrue(snapshot.current.isEmpty)
        XCTAssertEqual(snapshot.previous?.sourceText, "Still speaking")
        XCTAssertEqual(snapshot.previous?.translatedText, "まだ話しています")
    }

    func testForceFinalizeDiscardsSourceWithoutTranslation() {
        // Given: 翻訳が届いていない原文だけのライブ字幕
        let aggregator = SubtitleAggregator()
        _ = aggregator.replaceCurrent(
            sourceText: "Still speaking",
            translatedText: "",
            isTranslationCurrent: false,
            canFinalize: false
        )

        // When: 録音停止時に強制確定する
        let snapshot = aggregator.forceFinalize()

        // Then: 原文だけを確定せず、ライブ字幕も破棄する
        XCTAssertTrue(snapshot.current.isEmpty)
        XCTAssertNil(snapshot.previous)
    }

    func testForceFinalizeDiscardsStaleTranslationPair() {
        // Given: 新しい原文と旧訳文を一時表示しているライブ字幕
        let aggregator = SubtitleAggregator()
        _ = aggregator.replaceCurrent(
            sourceText: "A new sentence",
            translatedText: "古い翻訳です",
            isTranslationCurrent: false,
            canFinalize: false
        )

        // When: 録音停止時に強制確定する
        let snapshot = aggregator.forceFinalize()

        // Then: 誤った原文・訳文ペアを確定せず、ライブ字幕も破棄する
        XCTAssertTrue(snapshot.current.isEmpty)
        XCTAssertNil(snapshot.previous)
    }
}
