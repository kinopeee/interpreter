import XCTest
@testable import RealtimeTranslator

final class SpokenLanguageDetectorTests: XCTestCase {
    func testDetectsJapaneseWhenTextContainsJapaneseAndEnglish() {
        // Given: 日本語と英単語が混在する認識結果
        let text = "今日はCursorについて説明します"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text)

        // Then: 日本語と判定し、英語を翻訳先にする
        XCTAssertEqual(result, .japanese)
        XCTAssertEqual(result.translationTarget, .english)
    }

    func testDetectsEnglishFromLatinCharacters() {
        // Given: 大小文字を含む英語の認識結果
        let text = "Hello, how are you?"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text)

        // Then: 英語と判定し、日本語を翻訳先にする
        XCTAssertEqual(result, .english)
        XCTAssertEqual(result.translationTarget, .japanese)
    }

    func testDefersSingleLatinProperNoun() {
        // Given: 日英どちらの発話にも現れ得るLatin固有名詞
        let text = "Cursor"

        // When: 発話言語の証拠と判定結果を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)
        let result = SpokenLanguageDetector.detect(text)

        // Then: Latin一語だけでは英語に固定しない
        XCTAssertEqual(evidence, .ambiguousLatin)
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(result.translationTarget)
    }

    func testDefersSingleLatinAcronym() {
        // Given: 日英どちらでも使われるLatin略語
        let text = "MCP"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: 略語一語だけでは英語の証拠にしない
        XCTAssertEqual(evidence, .ambiguousLatin)
    }

    func testUsesMultipleLatinWordsAsEnglishEvidence() {
        // Given: 複数のLatin単語からなる英語文
        let text = "Open the file"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: 複数語は英語の証拠として扱う
        XCTAssertEqual(evidence, .english)
        XCTAssertEqual(SpokenLanguageDetector.detect(text), .english)
    }

    func testReturnsUnknownForEmptyText() {
        // Given: 空の認識結果
        let text = ""

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text)

        // Then: 言語・翻訳先ともに未判定になる
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(result.translationTarget)
    }

    func testReturnsUnknownForNumbersAndSymbols() {
        // Given: 言語を示す文字を含まない認識結果
        let text = "1234 / 56%"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text)

        // Then: 誤って日英どちらにも分類しない
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(result.translationTarget)
    }

    func testRecentEvidenceDetectsEnglishAfterJapanesePrefix() {
        // Given: 先頭は日本語、末尾はウィンドウを埋める複数の英単語
        let text = "今日は会議です Hello how are you doing today"

        // When: 全文判定と末尾ウィンドウ判定を比較する
        let full = SpokenLanguageDetector.evidence(in: text)
        let recent = SpokenLanguageDetector.recentEvidence(in: text, window: 16)

        // Then: 全文は日本語のまま、末尾は英語切替を検出する
        // （空白を残すことでラテン語が1語に潰れず english になる）
        XCTAssertEqual(full, .japanese)
        XCTAssertEqual(recent, .english)
    }

    func testRecentEvidenceDetectsJapaneseAfterEnglishPrefix() {
        // Given: 先頭は英語、末尾は日本語
        let text = "Hello how are you 今日は会議です"

        // When: 末尾ウィンドウで判定する
        let recent = SpokenLanguageDetector.recentEvidence(in: text, window: 16)

        // Then: 日本語切替を検出する
        XCTAssertEqual(recent, .japanese)
    }

    func testRecentEvidenceIgnoresWhitespaceOnlyTail() {
        // Given: 空白だけの原文
        let text = "   \n\t  "

        // When: 末尾ウィンドウで判定する
        let recent = SpokenLanguageDetector.recentEvidence(in: text, window: 16)

        // Then: 言語証拠なしとして扱う
        XCTAssertEqual(recent, .none)
    }

    func testRecentEvidenceKeepsAmbiguousLatinAtJapaneseTail() {
        // Given: 日本語がウィンドウ外へ流れ、末尾はLatin一語だけ
        let text = "今日は会議です" + String(repeating: "-", count: 24) + " Cursor"

        // When: 全文と末尾ウィンドウを比較する
        let full = SpokenLanguageDetector.evidence(in: text)
        let recent = SpokenLanguageDetector.recentEvidence(in: text, window: 16)

        // Then: 全文は日本語、末尾一語だけでは英語切替にしない
        XCTAssertEqual(full, .japanese)
        XCTAssertEqual(recent, .ambiguousLatin)
    }
}
