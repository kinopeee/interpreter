import XCTest
@testable import RealtimeTranslator

final class TranslationSourceNormalizerCommaTests: XCTestCase {
    func testRemovesJapaneseFillerFollowedByAsciiComma() {
        // Given: 文頭フィラーのあとにASCIIカンマがある日本語文
        let source = "あの,会議を始めます"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: フィラーとASCIIカンマを除去し、句点を補う
        XCTAssertEqual(normalized, "会議を始めます。")
    }

    func testRemovesJapaneseFillerFollowedByFullwidthComma() {
        // Given: 文頭フィラーのあとに全角カンマがある日本語文
        let source = "その，続きを話します"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .japanese
        )

        // Then: フィラーと全角カンマを除去し、本文だけを翻訳器へ渡す
        XCTAssertEqual(normalized, "続きを話します。")
    }
}
