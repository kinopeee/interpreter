import XCTest
@testable import RealtimeTranslator

final class SpokenLanguageDetectorTests: XCTestCase {
    func testDetectsJapaneseWhenTextContainsJapaneseAndEnglish() {
        // Given: 日本語と英単語が混在する認識結果
        let text = "今日はCursorについて説明します"

        // When: 日英ペアで発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .japaneseEnglish)

        // Then: 日本語と判定し、英語を翻訳先にする
        XCTAssertEqual(result, .japanese)
        XCTAssertEqual(
            LanguagePair.japaneseEnglish.translationTarget(for: result),
            .english
        )
    }

    func testDetectsEnglishFromLatinCharacters() {
        // Given: 大小文字を含む英語の認識結果
        let text = "Hello, how are you?"

        // When: 日英ペアで発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .japaneseEnglish)

        // Then: 英語と判定し、日本語を翻訳先にする
        XCTAssertEqual(result, .english)
        XCTAssertEqual(
            LanguagePair.japaneseEnglish.translationTarget(for: result),
            .japanese
        )
    }

    func testDefersSingleLatinProperNoun() {
        // Given: 日英どちらの発話にも現れ得るLatin固有名詞
        let text = "Cursor"

        // When: 発話言語の証拠と判定結果を調べる
        let evidence = SpokenLanguageDetector.evidence(
            in: text,
            pair: .japaneseEnglish
        )
        let result = SpokenLanguageDetector.detect(text, pair: .japaneseEnglish)

        // Then: Latin一語だけでは英語に固定しない
        XCTAssertEqual(evidence, .ambiguousLatin)
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(LanguagePair.japaneseEnglish.translationTarget(for: result))
    }

    func testDefersSingleLatinAcronym() {
        // Given: 日英どちらでも使われるLatin略語
        let text = "MCP"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(
            in: text,
            pair: .japaneseEnglish
        )

        // Then: 略語一語だけでは英語の証拠にしない
        XCTAssertEqual(evidence, .ambiguousLatin)
    }

    func testUsesMultipleLatinWordsAsEnglishEvidence() {
        // Given: 複数のLatin単語からなる英語文
        let text = "Open the file"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(
            in: text,
            pair: .japaneseEnglish
        )

        // Then: 複数語は英語の証拠として扱う
        XCTAssertEqual(evidence, .english)
        XCTAssertEqual(
            SpokenLanguageDetector.detect(text, pair: .japaneseEnglish),
            .english
        )
    }

    func testReturnsUnknownForEmptyText() {
        // Given: 空の認識結果
        let text = ""

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .japaneseEnglish)

        // Then: 言語・翻訳先ともに未判定になる
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(LanguagePair.japaneseEnglish.translationTarget(for: result))
    }

    func testReturnsUnknownForNumbersAndSymbols() {
        // Given: 言語を示す文字を含まない認識結果
        let text = "1234 / 56%"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .japaneseEnglish)

        // Then: 誤って日英どちらにも分類しない
        XCTAssertEqual(result, .unknown)
        XCTAssertNil(LanguagePair.japaneseEnglish.translationTarget(for: result))
    }

    func testTreatsLatinTextAsSpanishInJapaneseSpanishPair() {
        // Given: 日西ペアと複数語のスペイン語文
        let text = "Vamos a la reunión"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(
            in: text,
            pair: .japaneseSpanish
        )

        // Then: ラテン文字側の言語は1つに定まるためスペイン語とみなす
        XCTAssertEqual(evidence, .spanish)
        XCTAssertEqual(
            SpokenLanguageDetector.detect(text, pair: .japaneseSpanish),
            .spanish
        )
        XCTAssertEqual(
            LanguagePair.japaneseSpanish.translationTarget(for: .spanish),
            .japanese
        )
    }

    func testKeepsJapaneseEvidenceInJapaneseSpanishPair() {
        // Given: 日西ペアと日本語文字を含む認識結果
        let text = "スペイン語で話します"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .japaneseSpanish)

        // Then: 文字種で日本語を確定し、スペイン語を翻訳先にする
        XCTAssertEqual(result, .japanese)
        XCTAssertEqual(
            LanguagePair.japaneseSpanish.translationTarget(for: result),
            .spanish
        )
    }

    func testUsesSpanishOnlyCharactersAsImmediateEvidence() {
        // Given: 英西ペアと、スペイン語にしかない文字を含む1語の認識結果
        let text = "¿Sí?"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(
            in: text,
            pair: .englishSpanish
        )

        // Then: 反転疑問符だけでスペイン語を確定する
        XCTAssertEqual(evidence, .spanish)
    }

    func testUsesSpanishAccentAsEvidenceWithoutFunctionWords() {
        // Given: 英西ペアと、機能語を含まないアクセント付きスペイン語
        let text = "Buenos días"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .englishSpanish)

        // Then: アクセント付き母音を強い証拠として扱う
        XCTAssertEqual(result, .spanish)
    }

    func testUsesExclusiveFunctionWordsForSpanishInLatinPair() {
        // Given: 英西ペアと、アクセントを落として認識されたスペイン語文
        let text = "Vamos a hablar de la reunion"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .englishSpanish)

        // Then: スペイン語にしかない機能語の差でスペイン語と判定する
        XCTAssertEqual(result, .spanish)
    }

    func testUsesExclusiveFunctionWordsForEnglishInLatinPair() {
        // Given: 英西ペアと英語文
        let text = "Where is the meeting room?"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .englishSpanish)

        // Then: 英語にしかない機能語の差で英語と判定する
        XCTAssertEqual(result, .english)
    }

    func testDefersLatinPairWhenOnlySharedWordsAppear() {
        // Given: 英西ペアと、両言語で綴りが同じ語しかない認識結果
        let text = "Hotel Madrid"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(
            in: text,
            pair: .englishSpanish
        )

        // Then: 手掛かりが足りないうちは言語を確定しない
        XCTAssertEqual(evidence, .ambiguousLatin)
        XCTAssertEqual(
            SpokenLanguageDetector.detect(text, pair: .englishSpanish),
            .unknown
        )
    }

    func testDefersLatinPairWhenSingleExclusiveWordAppears() {
        // Given: 英西ペアと、スペイン語の機能語が1語だけの認識結果
        let text = "Madrid es"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(
            in: text,
            pair: .englishSpanish
        )

        // Then: 1語の一致では確定せず、証拠が増えるまで待つ
        XCTAssertEqual(evidence, .ambiguousLatin)
    }

    func testIgnoresJapaneseScriptOutsideThePair() {
        // Given: 英西ペアと、日本語文字が混ざった英語認識結果
        let text = "これ is the agenda"

        // When: 発話言語を判定する
        let result = SpokenLanguageDetector.detect(text, pair: .englishSpanish)

        // Then: ペア外の文字種に引きずられず、ラテン文字の語で判定する
        XCTAssertEqual(result, .english)
    }

    func testEvidenceWordListsAreMutuallyExclusive() {
        // Given: 英語とスペイン語それぞれの排他語リスト
        let spanish = SpokenLanguageDetector.spanishEvidenceWords
        let english = SpokenLanguageDetector.englishEvidenceWords

        // When: 両リストの共通部分を求める
        let shared = spanish.intersection(english)

        // Then: 同じ語が両言語の証拠になってはいけない
        XCTAssertTrue(shared.isEmpty, "両言語の証拠になる語: \(shared.sorted())")
    }
}
