import Foundation
import SwiftUI
@preconcurrency import Translation

/// Apple Translationのセッションを`translationTask`経由で受け取るためだけの
/// 1x1透明ビュー。`TranslationSession`は非Sendableでビュー寿命に依存するため、
/// このビューを破棄・再生成してはならない(AGENTS.mdの不変条件)。
///
/// 言語ペアの2方向それぞれにlive用(低遅延)とfinal用(品質優先)を持ち、
/// 4セッションを並行起動する。ペアを変えるときはビューを作り直さず、
/// `languagePair`だけを差し替えて`translationTask`の構成を更新する。
struct LocalTranslationHostView: View {
    let service: LocalTranslationService
    let languagePair: LanguagePair

    private var primary: SpokenLanguage { languagePair.languages[0] }
    private var secondary: SpokenLanguage { languagePair.languages[1] }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration(from: primary, priority: .live)) { session in
                await service.run(source: primary, priority: .live, session: session)
            }
            .translationTask(configuration(from: primary, priority: .final)) { session in
                await service.run(source: primary, priority: .final, session: session)
            }
            .translationTask(configuration(from: secondary, priority: .live)) { session in
                await service.run(source: secondary, priority: .live, session: session)
            }
            .translationTask(configuration(from: secondary, priority: .final)) { session in
                await service.run(source: secondary, priority: .final, session: session)
            }
    }

    private func configuration(
        from source: SpokenLanguage,
        priority: LocalTranslationPriority
    ) -> TranslationSession.Configuration? {
        guard let target = languagePair.translationTarget(for: source),
              let sourceLanguage = source.translationLanguage,
              let targetLanguage = target.translationLanguage
        else {
            return nil
        }

        switch priority {
        case .live:
            return liveConfiguration(source: sourceLanguage, target: targetLanguage)
        case .final:
            return finalConfiguration(source: sourceLanguage, target: targetLanguage)
        }
    }

    /// 発話途中の暫定訳向け。macOS 26.4以降は`.lowLatency`を優先する。
    private func liveConfiguration(
        source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        }
        return TranslationSession.Configuration(source: source, target: target)
    }

    /// 確定文向け。既定Configurationで品質を優先する。
    private func finalConfiguration(
        source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession.Configuration {
        TranslationSession.Configuration(source: source, target: target)
    }
}
