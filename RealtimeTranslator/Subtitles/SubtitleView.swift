import SwiftUI

enum SubtitleTextLayout {
    static let currentLineLimit = 2
    static let previousLineLimit = 1
    static let truncationMode: Text.TruncationMode = .head
    /// Approximate intrinsic size of `ProgressView().controlSize(.small)` for empty-slot reserve.
    static let bannerSpinnerSide: CGFloat = 16
}

enum SubtitleVisualStyle {
    static let previousBlockOpacity = 0.6
    static let sourceTextOpacity = 0.7
    static let visibleTranslatedTextOpacity = 1.0

    static func translatedTextOpacity(for subtitle: LiveSubtitle) -> Double {
        subtitle.translatedText.isEmpty ? 0 : visibleTranslatedTextOpacity
    }

    static func blockOpacity(
        isPrevious: Bool,
        previousOpacity: Double,
        isEmpty: Bool
    ) -> Double {
        guard !isEmpty else { return 0 }
        if isPrevious {
            return previousBlockOpacity * previousOpacity
        }
        return 1
    }
}

struct SubtitleView: View {
    let snapshot: SubtitleSnapshot
    let fontSize: Double
    let isEditingPosition: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusBannerSlot

            subtitleBlock(
                snapshot.previous ?? .empty,
                isPrevious: true
            )
            .opacity(
                SubtitleVisualStyle.blockOpacity(
                    isPrevious: true,
                    previousOpacity: snapshot.previousOpacity,
                    isEmpty: snapshot.previous?.isEmpty != false
                )
            )
            .accessibilityHidden(snapshot.previous?.isEmpty != false)

            currentSlot
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 1200, alignment: .leading)
        .overlay {
            if isEditingPosition {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.14))
                    )
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var statusBannerSlot: some View {
        let banner = snapshot.statusBanner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasBanner = !banner.isEmpty

        return HStack(spacing: 8) {
            // Keep the spinner out of the hierarchy when hidden so it does not keep animating.
            if hasBanner {
                ProgressView()
                    .controlSize(.small)
            } else {
                Color.clear
                    .frame(
                        width: SubtitleTextLayout.bannerSpinnerSide,
                        height: SubtitleTextLayout.bannerSpinnerSide
                    )
            }
            Text(hasBanner ? banner : " ")
                .font(.system(size: max(14, fontSize * 0.45), weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.95))
                .lineLimit(1, reservesSpace: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.46))
        )
        .shadow(color: .black.opacity(0.7), radius: 5, y: 2)
        .opacity(hasBanner ? 1 : 0)
        .accessibilityHidden(!hasBanner)
    }

    private var currentSlot: some View {
        let showListeningPlaceholder = snapshot.current.isEmpty
            && (snapshot.statusBanner == nil || snapshot.statusBanner?.isEmpty == true)

        return subtitleBlock(snapshot.current, isPrevious: false)
            .opacity(
                SubtitleVisualStyle.blockOpacity(
                    isPrevious: false,
                    previousOpacity: 1,
                    isEmpty: snapshot.current.isEmpty
                )
            )
            .accessibilityHidden(snapshot.current.isEmpty)
            .overlay(alignment: .leading) {
                if showListeningPlaceholder {
                    Text("録音中…")
                        .font(.system(size: max(14, fontSize * 0.45), weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .shadow(color: .black, radius: 3, y: 1)
                        .padding(.horizontal, 18)
                }
            }
    }

    @ViewBuilder
    private func subtitleBlock(
        _ subtitle: LiveSubtitle,
        isPrevious: Bool
    ) -> some View {
        let lineLimit = isPrevious
            ? SubtitleTextLayout.previousLineLimit
            : SubtitleTextLayout.currentLineLimit
        let sourceText = subtitle.sourceText.isEmpty ? " " : subtitle.sourceText
        let translatedText = subtitle.translatedText.isEmpty ? " " : subtitle.translatedText

        VStack(alignment: .leading, spacing: 4) {
            Text(sourceText)
                .font(
                    .system(
                        size: fontSize * 0.85,
                        weight: .medium
                    )
                )
                .foregroundStyle(Color.white.opacity(SubtitleVisualStyle.sourceTextOpacity))
                .lineLimit(lineLimit, reservesSpace: true)
                .truncationMode(SubtitleTextLayout.truncationMode)
                .frame(maxWidth: .infinity, alignment: .leading)
                .subtitleHalo()
                .opacity(subtitle.sourceText.isEmpty ? 0 : 1)
                .accessibilityHidden(subtitle.sourceText.isEmpty)

            Text(translatedText)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(lineLimit, reservesSpace: true)
                .truncationMode(SubtitleTextLayout.truncationMode)
                .frame(maxWidth: .infinity, alignment: .leading)
                .subtitleHalo()
                .opacity(SubtitleVisualStyle.translatedTextOpacity(for: subtitle))
                .accessibilityHidden(subtitle.translatedText.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.30))
        )
        .shadow(color: .black.opacity(0.58), radius: 8, y: 3)
    }
}

private extension View {
    func subtitleHalo() -> some View {
        self
            .shadow(color: .black.opacity(0.98), radius: 2, x: 1, y: 1)
            .shadow(color: .black.opacity(0.9), radius: 5)
    }
}

struct RecordingControlView: View {
    let state: TranslationState
    let onToggleRecording: () -> Void

    var body: some View {
        Button(action: onToggleRecording) {
            Label(buttonTitle, systemImage: buttonIcon)
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 112)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(isRecording ? .red : .green)
        .disabled(state == .closing)
        .accessibilityLabel(buttonTitle)
    }

    private var isRecording: Bool {
        switch state {
        case .connecting, .listening, .closing:
            return true
        case .idle, .error:
            return false
        }
    }

    private var buttonTitle: String {
        isRecording ? "録音終了" : "録音開始"
    }

    private var buttonIcon: String {
        isRecording ? "stop.fill" : "mic.fill"
    }
}
