import Foundation

/// 確定文をApple Translationへ渡す前の入力正規化。
/// 画面表示の原文は変更せず、翻訳器への入力だけを整える。
enum TranslationSourceNormalizer {
    private static let terminalPunctuation = CharacterSet(charactersIn: "。．.!？?！")

    private static let japaneseFillers = [
        "えーと",
        "えっと",
        "えー",
        "あのー",
        "あのう",
        "あの",
        "そのー",
        "その",
        "まぁ",
        "まあ",
    ]

    private static let englishFillers = [
        "um",
        "uh",
        "er",
        "ah",
        "like",
        "you know",
    ]

    /// final訳向けにテキストを正規化する。
    /// フィラー除去で空になった場合はトリム済み元テキストへフォールバックする。
    static func normalizeForFinalTranslation(
        _ text: String,
        language: SpokenLanguage
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let withoutFiller = removeLeadingFiller(trimmed, language: language)
        let body = withoutFiller.isEmpty ? trimmed : withoutFiller
        return ensureTerminalPunctuation(body, language: language)
    }

    private static func removeLeadingFiller(
        _ text: String,
        language: SpokenLanguage
    ) -> String {
        switch language {
        case .japanese:
            return removeLeadingJapaneseFiller(text)
        case .english:
            return removeLeadingEnglishFiller(text)
        case .unknown:
            return text
        }
    }

    private static func removeLeadingJapaneseFiller(_ text: String) -> String {
        for filler in japaneseFillers.sorted(by: { $0.count > $1.count }) {
            guard text.hasPrefix(filler) else { continue }
            var remainder = String(text.dropFirst(filler.count))
            if let first = remainder.first, "、,，".contains(first) {
                remainder.removeFirst()
            }
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func removeLeadingEnglishFiller(_ text: String) -> String {
        for filler in englishFillers.sorted(by: { $0.count > $1.count }) {
            guard let matchRange = text.range(
                of: #"^\s*"# + NSRegularExpression.escapedPattern(for: filler) + #"(?=[\s,]|$)"#,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                continue
            }
            var remainder = String(text[matchRange.upperBound...])
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.hasPrefix(",") {
                remainder.removeFirst()
                remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return remainder
        }
        return text
    }

    private static func ensureTerminalPunctuation(
        _ text: String,
        language: SpokenLanguage
    ) -> String {
        guard let last = text.unicodeScalars.last else { return text }
        if terminalPunctuation.contains(last) {
            return text
        }
        switch language {
        case .japanese:
            return text + "。"
        case .english:
            return text + "."
        case .unknown:
            return text
        }
    }
}
