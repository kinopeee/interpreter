import Foundation

/// 訳文が原文の実質コピー(未翻訳echo)かどうかの判定。
/// Apple Translationは崩れた認識文を訳せないとき入力をほぼそのまま返すことがあり、
/// そのペアを確定表示すると訳文欄に原語が出てしまう。
enum TranslationEchoDetector {
    private static let terminalPunctuation = CharacterSet(charactersIn: "。．.!？?！")

    /// 大文字小文字と終端句読点の違いを無視して原文と訳文を比較する。
    /// 「is on of comthing」→「is on of comthing.」のような無翻訳echoを検出する。
    static func isEcho(source: String, translated: String) -> Bool {
        let canonicalSource = canonicalForm(source)
        let canonicalTranslated = canonicalForm(translated)
        guard !canonicalSource.isEmpty, !canonicalTranslated.isEmpty else {
            return false
        }
        return canonicalSource == canonicalTranslated
    }

    private static func canonicalForm(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.unicodeScalars.last,
              terminalPunctuation.contains(last)
        {
            trimmed.removeLast()
        }
        return trimmed.lowercased()
    }
}
