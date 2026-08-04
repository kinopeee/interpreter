import Foundation
import os
import SwiftUI
@preconcurrency import Translation

enum LocalTranslationError: Error, LocalizedError, Sendable, Equatable {
    case sessionUnavailable
    case queueFull

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "ローカル翻訳モデルを準備できません"
        case .queueFull:
            return "ローカル翻訳の待機件数が上限に達しました"
        }
    }
}

/// Apple Translationの実セッションを抽象化する境界。テストではフェイクに差し替える。
@MainActor
protocol LocalTranslationSessionDriving: AnyObject {
    func prepare() async throws
    func translate(_ text: String) async throws -> String
}

@MainActor
private final class AppleTranslationSessionDriver: LocalTranslationSessionDriving {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func prepare() async throws {
        try await session.prepareTranslation()
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
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

/// 日→英と英→日の2レーンを持つローカル翻訳サービス。
/// 各レーンのワーカーは`LocalTranslationHostView`の`translationTask`から起動される。
@MainActor
final class LocalTranslationService: LocalTranslationServicing {
    private let jaToEnLane: TranslationLane
    private let enToJaLane: TranslationLane

    private(set) var isJapaneseToEnglishReady = false
    private(set) var isEnglishToJapaneseReady = false

    init(maxPendingFinals: Int = 32) {
        jaToEnLane = TranslationLane(finalCapacity: maxPendingFinals)
        enToJaLane = TranslationLane(finalCapacity: maxPendingFinals)
    }

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
            Task { @MainActor in
                lane.cancel(request)
            }
        }
    }

    func runJapaneseToEnglish(session: TranslationSession) async {
        await runJapaneseToEnglish(
            driver: AppleTranslationSessionDriver(session: session)
        )
    }

    func runJapaneseToEnglish(driver: any LocalTranslationSessionDriving) async {
        await run(
            driver: driver,
            lane: jaToEnLane,
            markReady: { self.isJapaneseToEnglishReady = $0 }
        )
    }

    func runEnglishToJapanese(session: TranslationSession) async {
        await runEnglishToJapanese(
            driver: AppleTranslationSessionDriver(session: session)
        )
    }

    func runEnglishToJapanese(driver: any LocalTranslationSessionDriving) async {
        await run(
            driver: driver,
            lane: enToJaLane,
            markReady: { self.isEnglishToJapaneseReady = $0 }
        )
    }

    private func run(
        driver: any LocalTranslationSessionDriving,
        lane: TranslationLane,
        markReady: @escaping (Bool) -> Void
    ) async {
        let signals = lane.beginRun()
        defer {
            markReady(false)
            lane.endRun()
        }

        var isPrepared: Bool
        switch await prepare(driver: driver, markReady: markReady) {
        case .success:
            isPrepared = true
        case .failure:
            isPrepared = false
        }
        guard !Task.isCancelled else { return }

        for await _ in signals {
            let shouldContinue = await drainQueue(
                driver: driver,
                lane: lane,
                markReady: markReady,
                isPrepared: &isPrepared
            )
            guard shouldContinue else { return }
        }
    }

    /// キューが空になるまで依頼を処理する。タスクがキャンセルされたら`false`を返す。
    private func drainQueue(
        driver: any LocalTranslationSessionDriving,
        lane: TranslationLane,
        markReady: @escaping (Bool) -> Void,
        isPrepared: inout Bool
    ) async -> Bool {
        while let request = lane.takeNext() {
            if !isPrepared {
                let preparation = await prepare(
                    for: request,
                    driver: driver,
                    lane: lane,
                    markReady: markReady
                )
                guard request.isActive else { continue }
                switch preparation {
                case .success:
                    isPrepared = true
                case .failure(let error):
                    request.complete(with: .failure(error))
                    if Task.isCancelled {
                        return false
                    }
                    continue
                }
            }

            await translate(request, driver: driver, lane: lane)
            if Task.isCancelled {
                return false
            }
        }
        return true
    }

    private func prepare(
        for request: PendingTranslationRequest,
        driver: any LocalTranslationSessionDriving,
        lane: TranslationLane,
        markReady: @escaping (Bool) -> Void
    ) async -> Result<Void, Error> {
        guard request.isActive else {
            return .failure(CancellationError())
        }
        let task = Task { @MainActor in
            await self.prepare(driver: driver, markReady: markReady)
        }
        lane.beginActiveWork(
            request: request,
            cancel: { task.cancel() }
        )
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        lane.finishActiveWork(request: request)
        return result
    }

    private func prepare(
        driver: any LocalTranslationSessionDriving,
        markReady: (Bool) -> Void
    ) async -> Result<Void, Error> {
        do {
            try await driver.prepare()
            markReady(true)
            return .success(())
        } catch {
            markReady(false)
            AppLogger.general.error(
                "Local translation preparation failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failure(error)
        }
    }

    private func translate(
        _ request: PendingTranslationRequest,
        driver: any LocalTranslationSessionDriving,
        lane: TranslationLane
    ) async {
        guard request.isActive else { return }
        let task = Task { @MainActor in
            try await driver.translate(request.text)
        }
        lane.beginActiveWork(
            request: request,
            cancel: { task.cancel() }
        )
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            request.cancel()
            task.cancel()
        }
        lane.finishActiveWork(request: request)
        request.complete(with: result)
    }
}
