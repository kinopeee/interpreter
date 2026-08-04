import SwiftUI

struct SubtitleView: View {
    let snapshot: SubtitleSnapshot
    let displayMode: SubtitleDisplayMode
    let fontSize: Double
    let isEditingPosition: Bool

    var body: some View {
        VStack(spacing: 10) {
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
                subtitleBlock(previous)
                    .opacity(snapshot.previousOpacity * 0.75)
            }

            if !snapshot.current.isEmpty {
                subtitleBlock(snapshot.current)
            } else if snapshot.statusBanner == nil {
                Text("録音中…")
                    .font(.system(size: max(14, fontSize * 0.45), weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .shadow(color: .black, radius: 3, y: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: 1200, maxHeight: .infinity, alignment: .bottom)
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
        .lineLimit(4)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func subtitleBlock(_ subtitle: LiveSubtitle) -> some View {
        VStack(spacing: 6) {
            if !subtitle.sourceText.isEmpty {
                Text(subtitle.sourceText)
                    .font(.system(size: fontSize * 0.85, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .subtitleHalo()
            }
            Text(subtitle.translatedText.isEmpty ? " " : subtitle.translatedText)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .subtitleHalo()
                .opacity(
                    subtitle.translatedText.isEmpty
                        ? 0
                        : (subtitle.isTranslationCurrent ? 1 : 0.72)
                )
                .accessibilityHidden(subtitle.translatedText.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
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
        case .connecting, .listening, .reconnecting, .closing:
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
