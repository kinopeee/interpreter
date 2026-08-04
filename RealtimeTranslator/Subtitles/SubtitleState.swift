import Foundation

enum SubtitleBlockState: String, Sendable, Equatable {
    case live
    case finalized
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
    var statusBanner: String?

    static let empty = SubtitleSnapshot(
        current: .empty,
        statusBanner: nil
    )

    var presentation: SubtitlePresentation {
        SubtitlePresentation(
            current: SubtitlePresentation.Block(current),
            statusBanner: statusBanner
        )
    }
}

struct SubtitlePresentation: Equatable, Sendable {
    struct Block: Equatable, Sendable {
        let sourceText: String
        let translatedText: String

        init(_ subtitle: LiveSubtitle) {
            sourceText = subtitle.sourceText
            translatedText = subtitle.translatedText
        }
    }

    let current: Block
    let statusBanner: String?
}
