import XCTest
@testable import RealtimeTranslator

final class SpokenLanguageScriptBoundaryTests: XCTestCase {
    func testDetectsKatakanaOnlyTextAsJapanese() {
        // Given: 漢字を含まないカタカナだけの認識結果
        let text = "カタカナです"

        // When: 発話言語を判定する
        let evidence = SpokenLanguageDetector.evidence(in: text)
        let result = SpokenLanguageDetector.detect(text)

        // Then: カタカナを日本語証拠として扱い、英語へ翻訳する
        XCTAssertEqual(evidence, .japanese)
        XCTAssertEqual(result, .japanese)
        XCTAssertEqual(result.translationTarget, .english)
    }

    func testDetectsHiraganaOnlyTextAsJapanese() {
        // Given: ひらがなだけの認識結果
        let text = "ひらがなだけ"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text)

        // Then: 日本語と判定する
        XCTAssertEqual(result, .japanese)
    }

    func testDetectsCJKExtensionAAsJapanese() {
        // Given: CJK統合漢字拡張A(U+3400)を含む認識結果
        let text = "\u{3400}の例"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: 基本漢字面の外でも日本語証拠にする
        XCTAssertEqual(evidence, .japanese)
        XCTAssertEqual(SpokenLanguageDetector.detect(text), .japanese)
    }

    func testDoesNotTreatHangulAsJapanese() {
        // Given: ハングルだけの認識結果
        let text = "안녕하세요"

        // When: 発話言語の証拠と判定結果を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)
        let result = SpokenLanguageDetector.detect(text)

        // Then: 韓国語を日本語レーンへ誤誘導しない
        XCTAssertEqual(evidence, .none)
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(result.translationTarget)
    }

    func testDoesNotTreatCyrillicWordsAsEnglish() {
        // Given: 複数語のキリル文字
        let text = "Привет мир"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)
        let result = SpokenLanguageDetector.detect(text)

        // Then: ラテン文字以外の単語数を英語証拠にしない
        XCTAssertEqual(evidence, .none)
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(result.translationTarget)
    }

    func testJapaneseScriptBeatsLatinWordCount() {
        // Given: 英単語を含むが日本語文字もある認識結果
        let text = "API と SDK の使い方"

        // When: 発話言語を判定する
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: ラテン複数語より日本語文字種を優先する
        XCTAssertEqual(evidence, .japanese)
        XCTAssertEqual(SpokenLanguageDetector.detect(text), .japanese)
    }

    func testCounterpartMapsJapaneseAndEnglish() {
        // Given: 日英と未判定の話者言語
        // When: 対向レーン言語を問い合わせる
        // Then: 日英は互いを指し、unknownはunknownのまま
        XCTAssertEqual(SpokenLanguage.japanese.counterpart, .english)
        XCTAssertEqual(SpokenLanguage.english.counterpart, .japanese)
        XCTAssertEqual(SpokenLanguage.unknown.counterpart, .unknown)
    }
}
