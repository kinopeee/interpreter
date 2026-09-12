import XCTest
@testable import RealtimeTranslator

final class TranslationSourceNormalizerRemainingFillerTests: XCTestCase {
    func testRemovesLeadingJapaneseFillersNotCoveredByExistingTests() {
        // Given: 既存テストが未使用の日本語フィラーを文頭に持つ確定文
        let cases = [
            ("まあ、今日は晴れです", "今日は晴れです。"),
            ("まぁ今日は晴れです", "今日は晴れです。"),
            ("あのう、会議です", "会議です。"),
            ("そのー、資料です", "資料です。")
        ]

        for (source, expected) in cases {
            // When: final訳向けに正規化する
            let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
                source,
                language: .japanese
            )

            // Then: 文頭フィラーを落とし、翻訳器へ本文だけを渡す
            XCTAssertEqual(normalized, expected, "input: \(source)")
        }
    }

    func testRemovesLeadingEnglishFillersNotCoveredByExistingTests() {
        // Given: 既存テストが未使用の英語フィラーを文頭に持つ確定文
        let cases = [
            ("like, this works", "this works."),
            ("ah, okay then", "okay then."),
            ("uh I think so", "I think so."),
            ("er, maybe later", "maybe later.")
        ]

        for (source, expected) in cases {
            // When: final訳向けに正規化する
            let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
                source,
                language: .english
            )

            // Then: 文頭フィラーを落とし、翻訳器へ本文だけを渡す
            XCTAssertEqual(normalized, expected, "input: \(source)")
        }
    }
}
