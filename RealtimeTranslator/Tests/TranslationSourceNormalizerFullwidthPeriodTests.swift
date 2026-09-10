import XCTest
@testable import RealtimeTranslator

final class TranslationSourceNormalizerFullwidthPeriodTests: XCTestCase {
    func testKeepsFullwidthIdeographicPeriod() {
        // Given: すでに全角ピリオドで終わっている日本語文
        let source = "確認しました．"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: 「。」を重ねず、認識された全角ピリオドを終端として維持する
        XCTAssertEqual(normalized, "確認しました．")
    }

    func testKeepsEnglishFullStopWithoutAppendingAnother() {
        // Given: 半角ピリオドで終わっている英文
        let source = "That is all."

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 追加の「.」を付けない
        XCTAssertEqual(normalized, "That is all.")
    }
}
