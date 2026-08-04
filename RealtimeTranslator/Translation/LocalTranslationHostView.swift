import Foundation
import SwiftUI
@preconcurrency import Translation

/// Apple Translationのセッションを`translationTask`経由で受け取るためだけの
/// 1x1透明ビュー。`TranslationSession`は非Sendableでビュー寿命に依存するため、
/// このビューを破棄・再生成してはならない(AGENTS.mdの不変条件)。
struct LocalTranslationHostView: View {
    let service: LocalTranslationService

    private let japanese = Locale.Language(identifier: "ja")
    private let english = Locale.Language(identifier: "en")

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(japaneseToEnglishConfiguration) { session in
                await service.runJapaneseToEnglish(session: session)
            }
            .translationTask(englishToJapaneseConfiguration) { session in
                await service.runEnglishToJapanese(session: session)
            }
    }

    private var japaneseToEnglishConfiguration: TranslationSession.Configuration {
        configuration(source: japanese, target: english)
    }

    private var englishToJapaneseConfiguration: TranslationSession.Configuration {
        configuration(source: english, target: japanese)
    }

    private func configuration(
        source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession.Configuration {
        // リアルタイム用途ではmacOS 26.4以降の.lowLatencyを優先する(AGENTS.md)。
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        }
        return TranslationSession.Configuration(source: source, target: target)
    }
}
