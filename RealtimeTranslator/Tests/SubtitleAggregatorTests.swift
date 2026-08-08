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
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testFinalizesPairedSubtitleOnTranslationPunctuation() {
        // Given: 句点付き原文を保持する字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("今日はCursorです。", now: now)

        // When: 終端記号付き翻訳を追加する
        let snapshot = aggregator.appendTranslation("This is Cursor.", now: now)

        // Then: 原文と翻訳を同じcurrentスロットへその場確定する
        XCTAssertEqual(snapshot.current.sourceText, "今日はCursorです。")
        XCTAssertEqual(snapshot.current.translatedText, "This is Cursor.")
        XCTAssertEqual(snapshot.current.state, .finalized)
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
        XCTAssertEqual(snapshot.current.state, .live)
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

        // Then: 1秒未満ではライブ、1秒超過後はcurrentにその場確定する
        XCTAssertEqual(before.current.state, .live)
        XCTAssertEqual(after.current.sourceText, "途中の文")
        XCTAssertEqual(after.current.translatedText, "An unfinished sentence")
        XCTAssertEqual(after.current.state, .finalized)
    }

    func testFinalizedPairStaysUntilNextUtterance() {
        // Given: その場確定ペアを保持する字幕集約器
        let aggregator = SubtitleAggregator()
        let start = Date()
        _ = aggregator.finalizePair(
            sourceText: "完了。",
            translatedText: "Done.",
            clearCurrent: true,
            now: start
        )

        // When: 十分時間が経った後にtickする
        let held = aggregator.tick(now: start.addingTimeInterval(60))

        // Then: タイマーでは消さず、次発話までcurrentに残す
        XCTAssertEqual(held.current.sourceText, "完了。")
        XCTAssertEqual(held.current.translatedText, "Done.")
        XCTAssertEqual(held.current.state, .finalized)
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

        // Then: currentスロットにその場確定で残す
        XCTAssertEqual(snapshot.current.sourceText, "確定文")
        XCTAssertEqual(snapshot.current.translatedText, "Finalized sentence")
        XCTAssertEqual(snapshot.current.state, .finalized)
    }

    func testNextUtteranceOverwritesInPlacePairWithoutHistory() {
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

        // Then: 確定ペアは履歴へ残さず消え、次の発話だけがcurrentになる
        XCTAssertEqual(snapshot.current.sourceText, "次の発話")
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testStaleFinalizePairDoesNotOverwriteCurrent() {
        // Given: 次の発話が既にcurrentにある字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.replaceCurrent(
            sourceText: "次の発話",
            translatedText: "",
            isTranslationCurrent: false,
            canFinalize: false,
            now: now
        )

        // When: 前の発話の遅延確定が届く
        let snapshot = aggregator.finalizePair(
            sourceText: "確定文",
            translatedText: "Finalized sentence",
            clearCurrent: false,
            now: now.addingTimeInterval(0.1)
        )

        // Then: 履歴がないため破棄し、currentの次発話を維持する
        XCTAssertEqual(snapshot.current.sourceText, "次の発話")
        XCTAssertEqual(snapshot.current.state, .live)
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

        // Then: ペアをcurrentスロットへその場確定する
        XCTAssertEqual(snapshot.current.sourceText, "Still speaking")
        XCTAssertEqual(snapshot.current.translatedText, "まだ話しています")
        XCTAssertEqual(snapshot.current.state, .finalized)
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
    }

    func testIdleTickDoesNotFinalizeWhenTranslationIsStale() {
        // Given: 旧訳文を残したまま原文だけが進んだライブ字幕
        var config = SubtitleAggregatorConfig()
        config.idleFinalizeInterval = 0.2
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()
        _ = aggregator.replaceCurrent(
            sourceText: "更新された原文",
            translatedText: "古い訳文です。",
            isTranslationCurrent: false,
            canFinalize: false,
            now: now
        )

        // When: アイドル確定間隔を超えてtickする
        let snapshot = aggregator.tick(now: now.addingTimeInterval(1))

        // Then: canFinalize=falseの旧訳文では確定せずliveを維持する
        XCTAssertEqual(snapshot.current.sourceText, "更新された原文")
        XCTAssertEqual(snapshot.current.translatedText, "古い訳文です。")
        XCTAssertEqual(snapshot.current.state, .live)
        XCTAssertFalse(snapshot.current.isTranslationCurrent)
        XCTAssertFalse(snapshot.current.canFinalize)
    }

    func testFinalizePairRejectsEmptyOrWhitespaceTranslation() {
        // Given: ライブペアを表示中の字幕集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.replaceCurrent(
            sourceText: "ライブ原文",
            translatedText: "Live translation",
            isTranslationCurrent: true,
            canFinalize: false,
            now: now
        )

        // When: 訳文が空または空白だけの確定要求が届く
        let emptyTranslation = aggregator.finalizePair(
            sourceText: "原文だけ",
            translatedText: "",
            clearCurrent: true,
            now: now.addingTimeInterval(0.1)
        )
        let whitespaceTranslation = aggregator.finalizePair(
            sourceText: "原文だけ",
            translatedText: "   ",
            clearCurrent: true,
            now: now.addingTimeInterval(0.2)
        )

        // Then: 原文だけの確定を拒否し、既存のcurrentを維持する
        XCTAssertEqual(emptyTranslation.current.sourceText, "ライブ原文")
        XCTAssertEqual(emptyTranslation.current.translatedText, "Live translation")
        XCTAssertEqual(emptyTranslation.current.state, .live)
        XCTAssertEqual(whitespaceTranslation.current.sourceText, "ライブ原文")
        XCTAssertEqual(whitespaceTranslation.current.translatedText, "Live translation")
        XCTAssertEqual(whitespaceTranslation.current.state, .live)
    }

    func testFinalizesPairWhenSourceExceedsMaxJapaneseLength() {
        // Given: 日本語上限を短くし、アイドル確定を事実上無効化した集約器
        var config = SubtitleAggregatorConfig()
        config.maxJapaneseCharacters = 10
        config.idleFinalizeInterval = 100
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()

        // When: 上限超過の原文と、句点のない訳文を追加する
        _ = aggregator.appendSource("あいうえおかきくけこさ", now: now)
        let snapshot = aggregator.appendTranslation("Too long source", now: now)

        // Then: 句点やアイドルを待たず長さ超過でその場確定する
        XCTAssertEqual(snapshot.current.sourceText.count, 11)
        XCTAssertEqual(snapshot.current.state, .finalized)
    }

    func testFinalizesPairWhenTranslationExceedsMaxEnglishLength() {
        // Given: 英語上限を短くし、アイドル確定を事実上無効化した集約器
        var config = SubtitleAggregatorConfig()
        config.maxEnglishCharacters = 20
        config.idleFinalizeInterval = 100
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()
        let longTranslation = String(repeating: "a", count: 21)

        // When: 短い原文と上限超過の英訳を追加する
        _ = aggregator.appendSource("短い原文", now: now)
        let snapshot = aggregator.appendTranslation(longTranslation, now: now)

        // Then: 訳文長超過でもペアをその場確定する
        XCTAssertEqual(snapshot.current.translatedText.count, 21)
        XCTAssertEqual(snapshot.current.state, .finalized)
    }

    func testAppendSourceAfterFinalizedStartsNewLiveUtterance() {
        // Given: currentにその場確定ペアがある集約器
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.finalizePair(
            sourceText: "確定文",
            translatedText: "Finalized.",
            clearCurrent: true,
            now: now
        )

        // When: appendSourceで次発話の原文deltaが届く
        let snapshot = aggregator.appendSource(
            "次の発話",
            now: now.addingTimeInterval(1)
        )

        // Then: 確定ペアを履歴へ残さず上書きし、訳文なしのliveへ戻す
        XCTAssertEqual(snapshot.current.sourceText, "次の発話")
        XCTAssertEqual(snapshot.current.translatedText, "")
        XCTAssertEqual(snapshot.current.state, .live)
        XCTAssertFalse(snapshot.current.isTranslationCurrent)
        XCTAssertFalse(snapshot.current.canFinalize)
    }
}
