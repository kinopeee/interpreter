import XCTest
@testable import RealtimeTranslator

final class SubtitleAggregatorExactLengthLimitTests: XCTestCase {
    func testSourceAtExactJapaneseLimitStaysLive() {
        // Given: 日本語上限ちょうどで、アイドル確定を事実上無効化した集約器
        var config = SubtitleAggregatorConfig()
        config.maxJapaneseCharacters = 10
        config.idleFinalizeInterval = 100
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()

        // When: 上限ちょうどの原文と、句点のない訳文を追加する
        _ = aggregator.appendSource("あいうえおかきくけこ", now: now)
        let snapshot = aggregator.appendTranslation("ten chars", now: now)

        // Then: 長さ超過(`>`)ではないため句点・アイドルなしでは確定しない
        XCTAssertEqual(snapshot.current.sourceText.count, 10)
        XCTAssertEqual(snapshot.current.state, .live)
    }

    func testTranslationAtExactEnglishLimitStaysLive() {
        // Given: 英語上限ちょうどで、アイドル確定を事実上無効化した集約器
        var config = SubtitleAggregatorConfig()
        config.maxEnglishCharacters = 20
        config.idleFinalizeInterval = 100
        let aggregator = SubtitleAggregator(config: config)
        let now = Date()
        let exactTranslation = String(repeating: "a", count: 20)

        // When: 短い原文と上限ちょうどの英訳を追加する
        _ = aggregator.appendSource("短い原文", now: now)
        let snapshot = aggregator.appendTranslation(exactTranslation, now: now)

        // Then: 訳文が上限ちょうどでも長さ超過では確定しない
        XCTAssertEqual(snapshot.current.translatedText.count, 20)
        XCTAssertEqual(snapshot.current.state, .live)
    }
}
