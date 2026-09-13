import XCTest
@testable import RealtimeTranslator

final class SpokenLanguageAbbreviationEvidenceTests: XCTestCase {
    func testPeriodSeparatedInitialsCountAsEnglishWords() {
        // Given: ピリオド区切りの欧文略語
        let text = "U.S.A."

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: 非ラテン文字で区切られた複数語として英語の証拠にする
        XCTAssertEqual(evidence, .english)
        XCTAssertEqual(SpokenLanguageDetector.detect(text), .english)
    }

    func testUndottedAcronymStaysAmbiguous() {
        // Given: 区切りのない欧文略語
        let text = "USA"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: Latin一語のままとし、英語へ固定しない
        XCTAssertEqual(evidence, .ambiguousLatin)
        XCTAssertEqual(SpokenLanguageDetector.detect(text), .unknown)
    }

    func testEnglishContractionCountsAsMultipleLatinWords() {
        // Given: アポストロフィで分節される英語の短縮形
        let text = "I'm"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: アポストロフィを語境界として英語の証拠にする
        XCTAssertEqual(evidence, .english)
        XCTAssertEqual(SpokenLanguageDetector.detect(text), .english)
    }

    func testHyphenatedLatinCompoundCountsAsEnglish() {
        // Given: ハイフンで繋がった欧文複合語
        let text = "real-time"

        // When: 発話言語の証拠を調べる
        let evidence = SpokenLanguageDetector.evidence(in: text)

        // Then: ハイフンを語境界として英語の証拠にする
        XCTAssertEqual(evidence, .english)
        XCTAssertEqual(SpokenLanguageDetector.detect(text), .english)
    }
}
