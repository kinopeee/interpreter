import XCTest
@testable import RealtimeTranslator

final class TranslationSourceNormalizerEnglishFillerFallbackTests: XCTestCase {
    func testFallsBackWhenEnglishFillerRemovalEmptiesText() {
        // Given: フィラーだけの英語入力
        let source = "um"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: 空文へせずトリム済み元テキストへフォールバックして句読点を付ける
        XCTAssertEqual(normalized, "um.")
    }

    func testFallsBackWhenMultiWordEnglishFillerIsTheWholeUtterance() {
        // Given: 複数語フィラーだけの英語入力
        let source = "You know"

        // When: final訳向けに正規化する
        let normalized = TranslationSourceNormalizer.normalizeForFinalTranslation(
            source,
            language: .english
        )

        // Then: フィラー除去で空になっても原文を残し、英文の終端句点を付ける
        XCTAssertEqual(normalized, "You know.")
    }
}
