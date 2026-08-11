import Foundation

/// テキストから推定した言語の証拠。
///
/// `ambiguousLatin` はラテン文字だが言語を断定できない場合。
/// 日本語話者のローマ字発話や固有名詞、英語とスペイン語で共通の語しか
/// 含まない文がこれに当たり、確定した言語証拠とは区別する。
enum SpokenLanguageEvidence: Equatable, Sendable {
    case japanese
    case english
    case spanish
    case ambiguousLatin
    case none
}

/// 認識テキストから話者言語を推定する。
///
/// 判定は言語ペアの文脈でのみ意味を持つ。日本語を含むペアは文字種だけで確定でき、
/// 英語とスペイン語のペアは同じラテン文字を使うため語彙の手掛かりで判別する。
enum SpokenLanguageDetector {
    /// スペイン語判定に必要なスコア差。1語の一致で言語を確定させないための下限。
    private static let confidentScoreMargin = 2
    /// アクセント付き母音を含む場合の加点。英語の自然な綴りにはほぼ現れない。
    private static let accentedVowelScore = 2

    static func detect(_ text: String, pair: LanguagePair) -> SpokenLanguage {
        switch evidence(in: text, pair: pair) {
        case .japanese:
            return .japanese
        case .english:
            return .english
        case .spanish:
            return .spanish
        case .ambiguousLatin, .none:
            return .unknown
        }
    }

    static func evidence(in text: String, pair: LanguagePair) -> SpokenLanguageEvidence {
        let scan = ScriptScan(text: text)

        // 日本語を含むペアでは、日本語文字が1つでもあれば他の手掛かりより優先する。
        if pair.contains(.japanese), scan.hasJapaneseScript {
            return .japanese
        }
        guard !scan.latinWords.isEmpty else { return .none }

        guard let latinLanguage = pair.latinLanguage else {
            return latinPairEvidence(scan)
        }
        // ラテン文字側の言語が1つに定まるペアでは語数だけで判断する。
        // 1語だけでは固有名詞やローマ字発話と区別できないため確定しない。
        return scan.latinWords.count == 1
            ? .ambiguousLatin
            : evidence(of: latinLanguage)
    }

    /// 英語とスペイン語のように同じ文字を使うペアの判別。
    ///
    /// スペイン語にしか現れない文字を最優先し、次に片方の言語にしか存在しない
    /// 機能語の出現数を比べる。差が小さいうちは確定させず`ambiguousLatin`に留める。
    private static func latinPairEvidence(
        _ scan: ScriptScan
    ) -> SpokenLanguageEvidence {
        if scan.hasSpanishExclusiveCharacter {
            return .spanish
        }

        var spanishScore = scan.hasSpanishAccentedVowel ? accentedVowelScore : 0
        var englishScore = 0
        for word in scan.latinWords {
            if spanishEvidenceWords.contains(word) {
                spanishScore += 1
            } else if englishEvidenceWords.contains(word) {
                englishScore += 1
            }
        }

        let margin = spanishScore - englishScore
        if margin >= confidentScoreMargin {
            return .spanish
        }
        if -margin >= confidentScoreMargin {
            return .english
        }
        return .ambiguousLatin
    }

    private static func evidence(of language: SpokenLanguage) -> SpokenLanguageEvidence {
        switch language {
        case .japanese:
            return .japanese
        case .english:
            return .english
        case .spanish:
            return .spanish
        case .unknown:
            return .none
        }
    }
}

/// 1回の走査で文字種・語・スペイン語特有の綴りをまとめて集める。
private struct ScriptScan {
    /// ひらがな・カタカナ・CJK拡張A・CJK統合漢字。
    private static let japaneseScriptRanges: [ClosedRange<UInt32>] = [
        0x3040...0x30FF,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
    ]
    /// ラテン文字の語を構成する scalar。Latin-1補助の文字を含めることで
    /// `está` や `mañana` を1語として数える。
    private static let latinWordRanges: [ClosedRange<UInt32>] = [
        0x0041...0x005A,
        0x0061...0x007A,
        0x00C0...0x00D6,
        0x00D8...0x00F6,
        0x00F8...0x00FF,
    ]
    /// スペイン語にしか現れない文字。`ñ`と反転した疑問符・感嘆符。
    private static let spanishExclusiveScalars: Set<UInt32> = [
        0x00F1, 0x00D1, 0x00BF, 0x00A1,
    ]
    /// スペイン語のアクセント付き母音。
    private static let spanishAccentedVowels: Set<UInt32> = [
        0x00E1, 0x00E9, 0x00ED, 0x00F3, 0x00FA, 0x00FC,
        0x00C1, 0x00C9, 0x00CD, 0x00D3, 0x00DA, 0x00DC,
    ]

    private(set) var hasJapaneseScript = false
    private(set) var latinWords: [String] = []
    private(set) var hasSpanishExclusiveCharacter = false
    private(set) var hasSpanishAccentedVowel = false

    init(text: String) {
        var currentWord = String.UnicodeScalarView()

        for scalar in text.unicodeScalars {
            let value = scalar.value

            if Self.japaneseScriptRanges.contains(where: { $0.contains(value) }) {
                hasJapaneseScript = true
                finishWord(&currentWord)
                continue
            }
            if Self.spanishExclusiveScalars.contains(value) {
                hasSpanishExclusiveCharacter = true
            }
            if Self.spanishAccentedVowels.contains(value) {
                hasSpanishAccentedVowel = true
            }
            if Self.latinWordRanges.contains(where: { $0.contains(value) }) {
                currentWord.append(scalar)
            } else {
                finishWord(&currentWord)
            }
        }
        finishWord(&currentWord)
    }

    private mutating func finishWord(_ word: inout String.UnicodeScalarView) {
        guard !word.isEmpty else { return }
        latinWords.append(String(word).lowercased())
        word = String.UnicodeScalarView()
    }
}

extension SpokenLanguageDetector {
    /// スペイン語にしか現れない語。英語でも使う綴り(`no` `a` `me` `he` `son` `sin`
    /// `soy` `era` `hay` `ya` など)は誤判定の原因になるため入れない。
    static let spanishEvidenceWords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "del", "al",
        "de", "en", "y", "que", "qué", "porque", "pero", "para", "por", "con",
        "muy", "más", "también", "ahora", "aquí", "allí", "así", "entonces",
        "pues", "esto", "esta", "este", "eso", "esa", "estos", "estas",
        "es", "está", "están", "estás", "estoy", "estamos", "ser", "somos",
        "hace", "hacer", "tiene", "tengo", "tienes", "puede", "puedo",
        "quiero", "quieres", "vamos", "vale", "algo", "nada", "mucho",
        "mucha", "muchos", "muchas", "cuando", "cuándo", "donde", "dónde",
        "quién", "quien", "cómo", "como", "hola", "gracias", "sí", "si",
        "señor", "señora", "bueno", "buenos", "buenas", "días", "noches",
        "tardes", "nosotros", "ellos", "ella", "usted", "ustedes", "yo",
        "tú", "su", "sus", "mi", "mis", "lo", "le", "les", "nos", "se",
        "bien", "mismo", "otro", "otra", "sobre", "desde", "hasta", "entre",
        "cada", "después", "antes", "siempre", "nunca", "aunque", "mientras",
        "necesito", "hablar", "trabajo", "todos", "todas",
    ]

    /// 英語にしか現れない語。スペイン語でも使う綴り(`no` `a` `me` `he` `son` `sin`
    /// `come` `van` `once` `pie` `red` `sale` `real` `final` など)は入れない。
    static let englishEvidenceWords: Set<String> = [
        "the", "and", "is", "are", "was", "were", "of", "to", "it", "its",
        "that", "this", "these", "those", "with", "for", "from", "you",
        "your", "yours", "they", "them", "their", "there", "here", "have",
        "has", "had", "not", "what", "when", "where", "which", "who", "whom",
        "whose", "how", "why", "because", "be", "been", "being", "do",
        "does", "did", "done", "will", "would", "shall", "should", "can",
        "could", "may", "might", "must", "about", "into", "over", "under",
        "after", "before", "again", "just", "only", "also", "very", "much",
        "many", "some", "any", "every", "each", "we", "our", "ours", "us",
        "i", "she", "her", "hers", "him", "his", "my", "mine", "at", "on",
        "in", "by", "or", "if", "as", "an", "so", "up", "out", "now", "then",
        "than", "know", "think", "need", "want", "going", "get", "got",
        "make", "take", "see", "say", "said", "like", "work", "time",
        "people", "thing", "things", "right", "good", "well", "yes", "okay",
        "thanks", "thank", "hello", "please", "sorry", "but", "all", "more",
        "most", "other", "same", "new", "first", "last", "let",
    ]
}
