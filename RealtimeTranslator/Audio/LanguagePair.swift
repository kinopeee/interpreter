import Foundation

/// 原文と訳文の言語ペア。翻訳は常にこの2言語のあいだで双方向に行う。
///
/// 認識レーン(`SpeechTranscriber`)も翻訳セッションもこのペアから組み立てるため、
/// ペアを変えるには両方を張り直す必要がある。録音中の切り替えは行わない。
enum LanguagePair: String, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case japaneseEnglish = "ja-en"
    case japaneseSpanish = "ja-es"
    case englishSpanish = "en-es"

    static let `default` = LanguagePair.japaneseEnglish

    /// 保存値が未知の場合も既定ペアで起動できるようにする。
    static func from(rawValue: String?) -> LanguagePair {
        guard let rawValue, let pair = LanguagePair(rawValue: rawValue) else {
            return .default
        }
        return pair
    }

    var id: String { rawValue }

    /// ペアを構成する2言語。認識レーンと翻訳セッションはこの順で作る。
    var languages: [SpokenLanguage] {
        switch self {
        case .japaneseEnglish:
            return [.japanese, .english]
        case .japaneseSpanish:
            return [.japanese, .spanish]
        case .englishSpanish:
            return [.english, .spanish]
        }
    }

    var displayName: String {
        let names = languages.map(\.displayName)
        return "\(names[0]) ↔ \(names[1])"
    }

    func contains(_ language: SpokenLanguage) -> Bool {
        languages.contains(language)
    }

    /// ペア内のもう一方の言語。ペア外と`unknown`に対しては`unknown`を返す。
    func counterpart(of language: SpokenLanguage) -> SpokenLanguage {
        let members = languages
        if language == members[0] {
            return members[1]
        }
        if language == members[1] {
            return members[0]
        }
        return .unknown
    }

    /// 話者言語に対する翻訳先。ペア外と`unknown`に対しては`nil`を返す。
    func translationTarget(for language: SpokenLanguage) -> SpokenLanguage? {
        let target = counterpart(of: language)
        return target == .unknown ? nil : target
    }

    /// 2言語の表記体系が異なるか。
    ///
    /// 異なる場合(日本語を含むペア)は文字種だけで話者言語を確定できる。
    /// 英語とスペイン語はどちらもラテン文字のため`false`になり、
    /// 語彙や綴りの手掛かりでしか判別できない。
    var hasDistinctScripts: Bool {
        contains(.japanese)
    }

    /// ラテン文字を使う唯一の言語。表記体系が異なるペアでのみ定まる。
    var latinLanguage: SpokenLanguage? {
        guard hasDistinctScripts else { return nil }
        return counterpart(of: .japanese)
    }
}
