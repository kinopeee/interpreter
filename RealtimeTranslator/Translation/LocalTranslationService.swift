import Foundation
import SwiftUI
@preconcurrency import Translation

enum LocalTranslationError: Error, LocalizedError, Sendable {
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "ローカル翻訳モデルを準備できません"
        }
    }
}

@MainActor
final class LocalTranslationService {
    private struct PendingRequest: @unchecked Sendable {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private let jaToEnStream: AsyncStream<PendingRequest>
    private let enToJaStream: AsyncStream<PendingRequest>
    private let jaToEnContinuation: AsyncStream<PendingRequest>.Continuation
    private let enToJaContinuation: AsyncStream<PendingRequest>.Continuation

    private(set) var isJapaneseToEnglishReady = false
    private(set) var isEnglishToJapaneseReady = false

    init() {
        (jaToEnStream, jaToEnContinuation) = AsyncStream.makeStream()
        (enToJaStream, enToJaContinuation) = AsyncStream.makeStream()
    }

    func translate(_ text: String, from language: SpokenLanguage) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(text: trimmed, continuation: continuation)
            switch language {
            case .japanese:
                jaToEnContinuation.yield(request)
            case .english:
                enToJaContinuation.yield(request)
            case .unknown:
                continuation.resume(throwing: LocalTranslationError.sessionUnavailable)
            }
        }
    }

    func runJapaneseToEnglish(session: TranslationSession) async {
        await run(
            session: session,
            stream: jaToEnStream,
            markReady: { self.isJapaneseToEnglishReady = $0 }
        )
    }

    func runEnglishToJapanese(session: TranslationSession) async {
        await run(
            session: session,
            stream: enToJaStream,
            markReady: { self.isEnglishToJapaneseReady = $0 }
        )
    }

    private func run(
        session: TranslationSession,
        stream: AsyncStream<PendingRequest>,
        markReady: @escaping (Bool) -> Void
    ) async {
        var preparationError: Error?
        do {
            try await session.prepareTranslation()
            markReady(true)
        } catch {
            preparationError = error
            markReady(false)
            AppLogger.general.error(
                "Local translation preparation failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        for await request in stream {
            if let preparationError {
                request.continuation.resume(throwing: preparationError)
                continue
            }

            do {
                let response = try await session.translate(request.text)
                request.continuation.resume(returning: response.targetText)
            } catch {
                request.continuation.resume(throwing: error)
            }
        }
    }
}

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
