import SwiftUI

enum SubtitleTextLayout {
    static let currentLineLimit = 2
    static let previousLineLimit = 1
    static let previousFontScale = 0.82
    static let truncationMode: Text.TruncationMode = .head
}

enum SubtitleVisualStyle {
    static func translatedTextOpacity(for subtitle: LiveSubtitle) -> Double {
        subtitle.translatedText.isEmpty ? 0 : 1
    }
}

struct SubtitleView: View {
    let snapshot: SubtitleSnapshot
    let fontSize: Double
    let isEditingPosition: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let banner = snapshot.statusBanner, !banner.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(banner)
                        .font(.system(size: max(14, fontSize * 0.45), weight: .semibold))
                        .foregroundStyle(Color.yellow.opacity(0.95))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.46))
                )
                .shadow(color: .black.opacity(0.7), radius: 5, y: 2)
            }

            if let previous = snapshot.previous, !previous.isEmpty {
                subtitleBlock(previous, isPrevious: true)
                    .opacity(snapshot.previousOpacity)
            }

            if !snapshot.current.isEmpty {
                subtitleBlock(snapshot.current, isPrevious: false)
            } else if snapshot.statusBanner == nil {
                Text("録音中…")
                    .font(.system(size: max(14, fontSize * 0.45), weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .shadow(color: .black, radius: 3, y: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 1200)
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
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func subtitleBlock(
        _ subtitle: LiveSubtitle,
        isPrevious: Bool
    ) -> some View {
        let lineLimit = isPrevious
            ? SubtitleTextLayout.previousLineLimit
            : SubtitleTextLayout.currentLineLimit
        let fontScale = isPrevious
            ? SubtitleTextLayout.previousFontScale
            : 1

        VStack(spacing: 4) {
            if !subtitle.sourceText.isEmpty {
                Text(subtitle.sourceText)
                    .font(
                        .system(
                            size: fontSize * 0.85 * fontScale,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(lineLimit)
                    .truncationMode(SubtitleTextLayout.truncationMode)
                    .fixedSize(horizontal: false, vertical: true)
                    .subtitleHalo()
            }
            Text(subtitle.translatedText.isEmpty ? " " : subtitle.translatedText)
                .font(.system(size: fontSize * fontScale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(lineLimit)
                .truncationMode(SubtitleTextLayout.truncationMode)
                .fixedSize(horizontal: false, vertical: true)
                .subtitleHalo()
                .opacity(SubtitleVisualStyle.translatedTextOpacity(for: subtitle))
                .accessibilityHidden(subtitle.translatedText.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
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
