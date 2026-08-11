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

/// 原文の言語ごとにlive/finalの2レーンを持つローカル翻訳サービス。
/// liveは低遅延、finalは品質優先のセッションへ振り分ける。
/// 各レーンのワーカーは`LocalTranslationHostView`の`translationTask`から起動される。
///
/// 翻訳先は言語ペアが決めるため、レーンは原文言語と優先度だけで識別する。
@MainActor
final class LocalTranslationService: LocalTranslationServicing {
    private struct LaneKey: Hashable {
        let source: SpokenLanguage
        let priority: LocalTranslationPriority
    }

    private let maxPendingFinals: Int
    private var lanes: [LaneKey: TranslationLane] = [:]
    /// final(品質優先)セッションを準備できた原文言語。liveセッションの状態は含めない。
    private(set) var readyFinalSources: Set<SpokenLanguage> = []

    init(maxPendingFinals: Int = 32) {
        self.maxPendingFinals = maxPendingFinals
    }

    func isFinalReady(source: SpokenLanguage) -> Bool {
        readyFinalSources.contains(source)
    }

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard language != .unknown else {
            throw LocalTranslationError.sessionUnavailable
        }

        let request = PendingTranslationRequest(text: trimmed, priority: priority)
        let lane = lane(source: language, priority: priority)

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

    /// 指定方向の翻訳セッションを消費し、そのレーンのワーカーとして動き続ける。
    func run(
        source: SpokenLanguage,
        priority: LocalTranslationPriority,
        session: TranslationSession
    ) async {
        await run(
            source: source,
            priority: priority,
            driver: AppleTranslationSessionDriver(session: session)
        )
    }

    func run(
        source: SpokenLanguage,
        priority: LocalTranslationPriority,
        driver: any LocalTranslationSessionDriving
    ) async {
        await run(
            driver: driver,
            lane: lane(source: source, priority: priority),
            markReady: { [weak self] isReady in
                guard priority == .final, let self else { return }
                if isReady {
                    self.readyFinalSources.insert(source)
                } else {
                    self.readyFinalSources.remove(source)
                }
            }
        )
    }

    private func lane(
        source: SpokenLanguage,
        priority: LocalTranslationPriority
    ) -> TranslationLane {
        let key = LaneKey(source: source, priority: priority)
        if let lane = lanes[key] {
            return lane
        }
        let lane = TranslationLane(finalCapacity: maxPendingFinals)
        lanes[key] = lane
        return lane
    }

    private func run(
        driver: any LocalTranslationSessionDriving,
        lane: TranslationLane,
        markReady: @escaping (Bool) -> Void
    ) async {
        let laneRun = lane.beginRun()
        defer {
            // 言語ペア変更で次のワーカーへ置き換わっている場合は、
            // 後始末が新しいワーカーの準備状態やキューを壊さないようにする。
            if lane.isCurrent(laneRun) {
                markReady(false)
                lane.endRun(laneRun)
            }
        }

        var isPrepared: Bool
        switch await prepare(driver: driver, markReady: markReady) {
        case .success:
            isPrepared = true
        case .failure:
            isPrepared = false
        }
        guard !Task.isCancelled else { return }

        for await _ in laneRun.signals {
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
