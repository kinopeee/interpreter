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

/// 日→英と英→日それぞれにlive/finalの2レーンを持つローカル翻訳サービス。
/// liveは低遅延、finalは品質優先のセッションへ振り分ける。
/// 各レーンのワーカーは`LocalTranslationHostView`の`translationTask`から起動される。
@MainActor
final class LocalTranslationService: LocalTranslationServicing {
    private let jaToEnLiveLane: TranslationLane
    private let jaToEnFinalLane: TranslationLane
    private let enToJaLiveLane: TranslationLane
    private let enToJaFinalLane: TranslationLane

    /// final(品質優先)セッションの準備状態。liveセッションの状態は含めない。
    private(set) var isJapaneseToEnglishReady = false
    private(set) var isEnglishToJapaneseReady = false

    init(maxPendingFinals: Int = 32) {
        jaToEnLiveLane = TranslationLane(finalCapacity: maxPendingFinals)
        jaToEnFinalLane = TranslationLane(finalCapacity: maxPendingFinals)
        enToJaLiveLane = TranslationLane(finalCapacity: maxPendingFinals)
        enToJaFinalLane = TranslationLane(finalCapacity: maxPendingFinals)
    }

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let request = PendingTranslationRequest(text: trimmed, priority: priority)
        let lane = try lane(for: language, priority: priority)

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

    func runJapaneseToEnglishLive(session: TranslationSession) async {
        await runJapaneseToEnglishLive(
            driver: AppleTranslationSessionDriver(session: session)
        )
    }

    func runJapaneseToEnglishLive(driver: any LocalTranslationSessionDriving) async {
        await run(
            driver: driver,
            lane: jaToEnLiveLane,
            markReady: { _ in }
        )
    }

    func runJapaneseToEnglishFinal(session: TranslationSession) async {
        await runJapaneseToEnglishFinal(
            driver: AppleTranslationSessionDriver(session: session)
        )
    }

    func runJapaneseToEnglishFinal(driver: any LocalTranslationSessionDriving) async {
        await run(
            driver: driver,
            lane: jaToEnFinalLane,
            markReady: { self.isJapaneseToEnglishReady = $0 }
        )
    }

    func runEnglishToJapaneseLive(session: TranslationSession) async {
        await runEnglishToJapaneseLive(
            driver: AppleTranslationSessionDriver(session: session)
        )
    }

    func runEnglishToJapaneseLive(driver: any LocalTranslationSessionDriving) async {
        await run(
            driver: driver,
            lane: enToJaLiveLane,
            markReady: { _ in }
        )
    }

    func runEnglishToJapaneseFinal(session: TranslationSession) async {
        await runEnglishToJapaneseFinal(
            driver: AppleTranslationSessionDriver(session: session)
        )
    }

    func runEnglishToJapaneseFinal(driver: any LocalTranslationSessionDriving) async {
        await run(
            driver: driver,
            lane: enToJaFinalLane,
            markReady: { self.isEnglishToJapaneseReady = $0 }
        )
    }

    private func lane(
        for language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) throws -> TranslationLane {
        switch (language, priority) {
        case (.japanese, .live):
            return jaToEnLiveLane
        case (.japanese, .final):
            return jaToEnFinalLane
        case (.english, .live):
            return enToJaLiveLane
        case (.english, .final):
            return enToJaFinalLane
        case (.unknown, _):
            throw LocalTranslationError.sessionUnavailable
        }
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
