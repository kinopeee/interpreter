import Foundation

enum SubtitleBlockState: String, Sendable, Equatable {
    case live
    case finalized
    case fading
}

struct LiveSubtitle: Equatable, Sendable {
    var sourceText: String
    var translatedText: String
    var lastUpdatedAt: Date
    var state: SubtitleBlockState
    var isTranslationCurrent = false
    var canFinalize = false

    static let empty = LiveSubtitle(
        sourceText: "",
        translatedText: "",
        lastUpdatedAt: .distantPast,
        state: .live,
        isTranslationCurrent: false,
        canFinalize: false
    )

    var isEmpty: Bool {
        sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SubtitleSnapshot: Equatable, Sendable {
    var current: LiveSubtitle
    var previous: LiveSubtitle?
    var statusBanner: String?
    var previousOpacity: Double

    static let empty = SubtitleSnapshot(
        current: .empty,
        previous: nil,
        statusBanner: nil,
        previousOpacity: 1
    )
}
