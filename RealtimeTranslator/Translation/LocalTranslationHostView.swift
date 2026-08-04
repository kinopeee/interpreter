import Foundation
import SwiftUI
@preconcurrency import Translation

/// Apple Translationのセッションを`translationTask`経由で受け取るためだけの
/// 1x1透明ビュー。`TranslationSession`は非Sendableでビュー寿命に依存するため、
/// このビューを破棄・再生成してはならない(AGENTS.mdの不変条件)。
///
/// live用(低遅延)とfinal用(品質優先)の4セッションを並行起動する。
struct LocalTranslationHostView: View {
    let service: LocalTranslationService

    private let japanese = Locale.Language(identifier: "ja")
    private let english = Locale.Language(identifier: "en")

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(japaneseToEnglishLiveConfiguration) { session in
                await service.runJapaneseToEnglishLive(session: session)
            }
            .translationTask(japaneseToEnglishFinalConfiguration) { session in
                await service.runJapaneseToEnglishFinal(session: session)
            }
            .translationTask(englishToJapaneseLiveConfiguration) { session in
                await service.runEnglishToJapaneseLive(session: session)
            }
            .translationTask(englishToJapaneseFinalConfiguration) { session in
                await service.runEnglishToJapaneseFinal(session: session)
            }
    }

    private var japaneseToEnglishLiveConfiguration: TranslationSession.Configuration {
        liveConfiguration(source: japanese, target: english)
    }

    private var japaneseToEnglishFinalConfiguration: TranslationSession.Configuration {
        finalConfiguration(source: japanese, target: english)
    }

    private var englishToJapaneseLiveConfiguration: TranslationSession.Configuration {
        liveConfiguration(source: english, target: japanese)
    }

    private var englishToJapaneseFinalConfiguration: TranslationSession.Configuration {
        finalConfiguration(source: english, target: japanese)
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
