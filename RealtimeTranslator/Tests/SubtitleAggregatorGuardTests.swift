import XCTest
@testable import RealtimeTranslator

final class SubtitleAggregatorGuardTests: XCTestCase {
    func testEmptyAppendsDoNotChangeSnapshot() {
        // Given: 原文と訳文を持つライブ字幕
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("Hello", now: now)
        _ = aggregator.appendTranslation("こんにちは", now: now)

        // When: 空deltaを追加する
        let afterEmptySource = aggregator.appendSource("", now: now.addingTimeInterval(0.1))
        let afterEmptyTranslation = aggregator.appendTranslation(
            "",
            now: now.addingTimeInterval(0.2)
        )

        // Then: 本文も更新時刻も変えない
        XCTAssertEqual(afterEmptySource.current.sourceText, "Hello")
        XCTAssertEqual(afterEmptySource.current.translatedText, "こんにちは")
        XCTAssertEqual(afterEmptySource.current.lastUpdatedAt, now)
        XCTAssertEqual(afterEmptyTranslation.current.lastUpdatedAt, now)
        XCTAssertEqual(afterEmptyTranslation.current.state, .live)
    }

    func testResetClearsCurrentPairAndStatusBanner() {
        // Given: ステータスとライブ字幕を持つ集約器
        let aggregator = SubtitleAggregator()
        aggregator.setStatusBanner("録音中… 話してください")
        _ = aggregator.replaceCurrent(
            sourceText: "残してはいけない原文",
            translatedText: "Stale pair"
        )

        // When: 集約器をリセットする
        aggregator.reset()
        let snapshot = aggregator.snapshot()

        // Then: 字幕もバナーも空になる
        XCTAssertTrue(snapshot.current.isEmpty)
        XCTAssertNil(snapshot.statusBanner)
    }

    func testStatusBannerSurvivesSubtitleUpdatesUntilCleared() {
        // Given: 準備中バナーを出した集約器
        let aggregator = SubtitleAggregator()
        aggregator.setStatusBanner("ローカル音声認識を準備中…")

        // When: 字幕を更新したあとバナーを消す
        let withBanner = aggregator.appendSource("準備後の原文")
        aggregator.setStatusBanner(nil)
        let cleared = aggregator.snapshot()

        // Then: 字幕更新ではバナーを消さず、明示クリアで消える
        XCTAssertEqual(withBanner.statusBanner, "ローカル音声認識を準備中…")
        XCTAssertEqual(withBanner.current.sourceText, "準備後の原文")
        XCTAssertNil(cleared.statusBanner)
    }

    func testHangulTranslationUsesEnglishLengthLimit() {
        // Given: 日本語60字を超えるが英語120字未満のハングル訳
        var config = SubtitleAggregatorConfig()
        config.maxJapaneseCharacters = 60
        config.maxEnglishCharacters = 120
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()
        let hangul = String(repeating: "한", count: 70)
        _ = aggregator.appendSource("Hello", now: now)

        // When: 句点なしのハングル訳を追加する
        let snapshot = aggregator.appendTranslation(hangul, now: now)

        // Then: ハングルをCJK扱いで60字確定せず、ライブのまま残す
        XCTAssertEqual(snapshot.current.translatedText, hangul)
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testLatinTranslationBelowEnglishLimitStaysLive() {
        // Given: 日本語60字を超えるが英語120字未満のラテン訳
        var config = SubtitleAggregatorConfig()
        config.maxJapaneseCharacters = 60
        config.maxEnglishCharacters = 120
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()
        let latin = String(repeating: "a", count: 61)
        _ = aggregator.appendSource("原文", now: now)

        // When: 句点なしのラテン訳を追加する
        let snapshot = aggregator.appendTranslation(latin, now: now)

        // Then: 英語上限を使い、日本語60字では確定しない
        XCTAssertEqual(snapshot.current.translatedText, latin)
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testCJKTranslationUsesJapaneseLengthLimit() {
        // Given: 英語レーン向けでもCJKを含む訳文
        var config = SubtitleAggregatorConfig()
        config.maxJapaneseCharacters = 60
        config.maxEnglishCharacters = 120
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()
        let cjk = String(repeating: "あ", count: 61)
        _ = aggregator.appendSource("Source", now: now)

        // When: 61字の日本語訳を追加する
        let snapshot = aggregator.appendTranslation(cjk, now: now)

        // Then: 文字種を優先して日本語上限でその場確定する
        XCTAssertEqual(snapshot.current.translatedText, cjk)
        XCTAssertEqual(snapshot.current.state, .finalized)
    }

    func testTranslationQuestionMarkFinalizesPair() {
        // Given: 原文待ちのライブ字幕
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("準備はできた？", now: now)

        // When: 終端が疑問符の訳文を追加する
        let snapshot = aggregator.appendTranslation("Are you ready?", now: now)

        // Then: 訳文の終端記号でペアを確定する
        XCTAssertEqual(snapshot.current.state, .finalized)
        XCTAssertEqual(snapshot.current.translatedText, "Are you ready?")
    }

    func testTranslationExclamationMarkFinalizesPair() {
        // Given: 原文待ちのライブ字幕
        let aggregator = SubtitleAggregator()
        let now = Date()
        _ = aggregator.appendSource("すごい", now: now)

        // When: 終端が感嘆符の訳文を追加する
        let snapshot = aggregator.appendTranslation("Amazing!", now: now)

        // Then: ピリオド以外の終端でもペアを確定する
        XCTAssertEqual(snapshot.current.state, .finalized)
    }
}
