import Foundation

enum SpokenLanguage: Equatable, Hashable, Sendable {
    case japanese
    case english
    case unknown

    var translationTarget: TranslationTarget? {
        switch self {
        case .japanese:
            return .english
        case .english:
            return .japanese
        case .unknown:
            return nil
        }
    }

    /// 日英2レーン構成における相手側レーンの言語。
    var counterpart: SpokenLanguage {
        switch self {
        case .japanese:
            return .english
        case .english:
            return .japanese
        case .unknown:
            return .unknown
        }
    }
}

enum TranslationTarget: String, Equatable, Sendable {
    case english = "en"
    case japanese = "ja"
}
