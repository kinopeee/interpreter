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
}

enum TranslationTarget: String, Equatable, Sendable {
    case english = "en"
    case japanese = "ja"
}

enum SpokenLanguageDetector {
    static func detect(_ text: String) -> SpokenLanguage {
        var japaneseCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                japaneseCount += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            default:
                continue
            }
        }

        if japaneseCount > 0 {
            return .japanese
        }
        if latinCount > 0 {
            return .english
        }
        return .unknown
    }
}

struct SpeechRecognitionCandidate: Equatable, Sendable {
    let text: String
    let language: SpokenLanguage
    let confidence: Double
    let isFinal: Bool
    let startTime: Double
    let endTime: Double

    var score: Double {
        let detected = SpokenLanguageDetector.detect(text)
        let scriptBonus = detected == language ? 0.1 : -0.15
        return confidence + scriptBonus
    }

    func overlaps(_ other: SpeechRecognitionCandidate) -> Bool {
        abs(startTime - other.startTime) < 1.0
            || (startTime <= other.endTime && endTime >= other.startTime)
    }
}

struct BilingualSpeechArbiter: Sendable {
    private(set) var activeLanguage: SpokenLanguage?
    private var candidates: [SpokenLanguage: SpeechRecognitionCandidate] = [:]

    var hasPendingCandidates: Bool {
        !candidates.isEmpty
    }

    mutating func reset() {
        activeLanguage = nil
        candidates.removeAll(keepingCapacity: true)
    }

    mutating func submit(
        _ candidate: SpeechRecognitionCandidate
    ) -> SpeechRecognitionCandidate? {
        if let activeLanguage {
            guard candidate.language == activeLanguage else { return nil }
            if candidate.isFinal {
                reset()
            }
            return candidate
        }

        candidates[candidate.language] = candidate
        let overlapping = candidates.values.filter { $0.overlaps(candidate) }
        guard overlapping.count >= 2 else { return nil }
        return selectAndLock(from: overlapping)
    }

    mutating func selectBestAvailable() -> SpeechRecognitionCandidate? {
        guard activeLanguage == nil, !candidates.isEmpty else { return nil }
        return selectAndLock(from: Array(candidates.values))
    }

    private mutating func selectAndLock(
        from candidates: [SpeechRecognitionCandidate]
    ) -> SpeechRecognitionCandidate? {
        guard let winner = candidates.max(by: { $0.score < $1.score }) else {
            return nil
        }
        activeLanguage = winner.language
        if winner.isFinal {
            reset()
        }
        return winner
    }
}
