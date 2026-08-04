import Foundation
import os
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

enum LocalTranslationPriority: Sendable {
    case live
    case final
}

struct LatestTranslationScheduler<Item> {
    private var finalItems: [Item] = []
    private var liveItem: Item?

    var isEmpty: Bool {
        finalItems.isEmpty && liveItem == nil
    }

    /// Returns a superseded live item that the caller should cancel.
    mutating func enqueue(_ item: Item, priority: LocalTranslationPriority) -> Item? {
        switch priority {
        case .live:
            let superseded = liveItem
            liveItem = item
            return superseded
        case .final:
            let superseded = liveItem
            liveItem = nil
            finalItems.append(item)
            return superseded
        }
    }

    mutating func next() -> Item? {
        if !finalItems.isEmpty {
            return finalItems.removeFirst()
        }
        defer { liveItem = nil }
        return liveItem
    }
}

private final class PendingTranslationRequest: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, Error>?
        var isCancelled = false
        var isFinished = false
    }

    let text: String
    let priority: LocalTranslationPriority
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(text: String, priority: LocalTranslationPriority) {
        self.text = text
        self.priority = priority
    }

    var isActive: Bool {
        state.withLock { !$0.isCancelled && !$0.isFinished }
    }

    func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
        let installed = state.withLock { state in
            guard !state.isCancelled, !state.isFinished else { return false }
            state.continuation = continuation
            return true
        }
        if !installed {
            continuation.resume(throwing: CancellationError())
        }
        return installed
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<String, Error>? in
            guard !state.isCancelled, !state.isFinished else { return nil }
            state.isCancelled = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func complete(with result: Result<String, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<String, Error>? in
            guard !state.isCancelled, !state.isFinished else { return nil }
            state.isFinished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        guard let continuation else { return }

        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
private final class TranslationLane {
    let signals: AsyncStream<Void>

    private let signalContinuation: AsyncStream<Void>.Continuation
    private var scheduler = LatestTranslationScheduler<PendingTranslationRequest>()

    init() {
        (signals, signalContinuation) = AsyncStream.makeStream()
    }

    func submit(_ request: PendingTranslationRequest) {
        guard request.isActive else { return }
        let superseded = scheduler.enqueue(request, priority: request.priority)
        superseded?.cancel()
        signalContinuation.yield(())
    }

    func takeNext() -> PendingTranslationRequest? {
        while let request = scheduler.next() {
            if request.isActive {
                return request
            }
        }
        return nil
    }
}

@MainActor
protocol LocalTranslationServicing: AnyObject {
    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String
}

@MainActor
final class LocalTranslationService: LocalTranslationServicing {
    private let jaToEnLane = TranslationLane()
    private let enToJaLane = TranslationLane()

    private(set) var isJapaneseToEnglishReady = false
    private(set) var isEnglishToJapaneseReady = false

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let request = PendingTranslationRequest(text: trimmed, priority: priority)
        let lane: TranslationLane
        switch language {
        case .japanese:
            lane = jaToEnLane
        case .english:
            lane = enToJaLane
        case .unknown:
            throw LocalTranslationError.sessionUnavailable
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                lane.submit(request)
            }
        } onCancel: {
            request.cancel()
        }
    }

    func runJapaneseToEnglish(session: TranslationSession) async {
        await run(
            session: session,
            lane: jaToEnLane,
            markReady: { self.isJapaneseToEnglishReady = $0 }
        )
    }

    func runEnglishToJapanese(session: TranslationSession) async {
        await run(
            session: session,
            lane: enToJaLane,
            markReady: { self.isEnglishToJapaneseReady = $0 }
        )
    }

    private func run(
        session: TranslationSession,
        lane: TranslationLane,
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

        for await _ in lane.signals {
            while let request = lane.takeNext() {
                if let preparationError {
                    request.complete(with: .failure(preparationError))
                    continue
                }

                do {
                    let response = try await session.translate(request.text)
                    request.complete(with: .success(response.targetText))
                } catch {
                    request.complete(with: .failure(error))
                }
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
