import XCTest
@testable import RealtimeTranslator

final class LanguagePairTests: XCTestCase {
    func testEachPairTranslatesBothDirections() {
        // Given: 選択できるすべての言語ペア
        let pairs = LanguagePair.allCases

        // When: 各ペアの2言語について翻訳先を求める
        // Then: どちらの言語からも相手言語へ翻訳する
        for pair in pairs {
            let languages = pair.languages
            XCTAssertEqual(languages.count, 2, "\(pair.rawValue)")
            XCTAssertEqual(
                pair.translationTarget(for: languages[0]),
                languages[1],
                pair.rawValue
            )
            XCTAssertEqual(
                pair.translationTarget(for: languages[1]),
                languages[0],
                pair.rawValue
            )
        }
    }

    func testLanguagesOutsideThePairHaveNoTarget() {
        // Given: 日英ペア
        let pair = LanguagePair.japaneseEnglish

        // When: ペア外の言語と未判定の言語について翻訳先を求める
        // Then: 翻訳先を返さず、相手言語も未判定にする
        XCTAssertNil(pair.translationTarget(for: .spanish))
        XCTAssertNil(pair.translationTarget(for: .unknown))
        XCTAssertEqual(pair.counterpart(of: .spanish), .unknown)
        XCTAssertEqual(pair.counterpart(of: .unknown), .unknown)
        XCTAssertFalse(pair.contains(.spanish))
    }

    func testOnlyPairsWithJapaneseHaveDistinctScripts() {
        // Given: 日本語を含むペアと、ラテン文字だけのペア
        // When: 表記体系が異なるかを調べる
        // Then: 英西だけは文字種で判別できないペアとして扱う
        XCTAssertTrue(LanguagePair.japaneseEnglish.hasDistinctScripts)
        XCTAssertTrue(LanguagePair.japaneseSpanish.hasDistinctScripts)
        XCTAssertFalse(LanguagePair.englishSpanish.hasDistinctScripts)
        XCTAssertEqual(LanguagePair.japaneseEnglish.latinLanguage, .english)
        XCTAssertEqual(LanguagePair.japaneseSpanish.latinLanguage, .spanish)
        XCTAssertNil(LanguagePair.englishSpanish.latinLanguage)
    }

    func testEachPairLanguageHasSpeechAndTranslationIdentifiers() {
        // Given: すべてのペアが使う言語
        let languages = Set(LanguagePair.allCases.flatMap(\.languages))

        // When: 認識ロケールと翻訳言語を取り出す
        // Then: どの言語も両方の識別子を持ち、認識・翻訳を構成できる
        XCTAssertEqual(languages, [.japanese, .english, .spanish])
        for language in languages {
            XCTAssertNotNil(language.speechLocaleIdentifier, "\(language)")
            XCTAssertNotNil(language.translationLanguage, "\(language)")
        }
        XCTAssertNil(SpokenLanguage.unknown.speechLocaleIdentifier)
        XCTAssertNil(SpokenLanguage.unknown.translationLanguage)
    }

    func testUnknownStoredValueFallsBackToDefaultPair() {
        // Given: 保存値が壊れている、または未保存の設定
        // When: 保存値からペアを復元する
        // Then: 既定の日英ペアで起動できる
        XCTAssertEqual(LanguagePair.from(rawValue: nil), .japaneseEnglish)
        XCTAssertEqual(LanguagePair.from(rawValue: "ja-ko"), .japaneseEnglish)
        XCTAssertEqual(LanguagePair.from(rawValue: "en-es"), .englishSpanish)
    }
}
