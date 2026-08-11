import Foundation

/// 認識・翻訳の対象言語。`unknown` は判定前と判定不能の両方を表す。
enum SpokenLanguage: Equatable, Hashable, Sendable {
    case japanese
    case english
    case spanish
    case unknown

    /// `SpeechTranscriber` へ渡すロケール識別子。
    var speechLocaleIdentifier: String? {
        switch self {
        case .japanese:
            return "ja-JP"
        case .english:
            return "en-US"
        case .spanish:
            return "es-ES"
        case .unknown:
            return nil
        }
    }

    /// Apple Translationのセッション構成へ渡す言語。
    var translationLanguage: Locale.Language? {
        switch self {
        case .japanese:
            return Locale.Language(identifier: "ja")
        case .english:
            return Locale.Language(identifier: "en")
        case .spanish:
            return Locale.Language(identifier: "es")
        case .unknown:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .japanese:
            return "日本語"
        case .english:
            return "英語"
        case .spanish:
            return "スペイン語"
        case .unknown:
            return "不明"
        }
    }
}
