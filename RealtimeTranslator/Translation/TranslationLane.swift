import Foundation
import os

/// 1件の翻訳依頼。continuationの設置と結果解決が別スレッドから競合しても
/// 安全なように、状態遷移をロックで守る境界型(`@unchecked Sendable`)。
final class PendingTranslationRequest: @unchecked Sendable {
    private enum State {
        case awaitingContinuation
        case pending(CheckedContinuation<String, Error>)
        case resolved(Result<String, Error>)
    }

    let text: String
    let priority: LocalTranslationPriority
    private let state = OSAllocatedUnfairLock(initialState: State.awaitingContinuation)

    init(text: String, priority: LocalTranslationPriority) {
        self.text = text
        self.priority = priority
    }

    var isActive: Bool {
        state.withLock { state in
            switch state {
            case .awaitingContinuation, .pending:
                return true
            case .resolved:
                return false
            }
        }
    }

    /// continuationを設置する。設置前に解決済みだった場合はその場でresumeし、
    /// falseを返す(呼び出し側はキュー投入をスキップする)。
    func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
        let resolvedResult = state.withLock {
            state -> Result<String, Error>? in
            switch state {
            case .awaitingContinuation:
                state = .pending(continuation)
                return nil
            case .pending:
                preconditionFailure("Translation continuation installed twice")
            case .resolved(let result):
                return result
            }
        }
        if let resolvedResult {
            continuation.resume(with: resolvedResult)
            return false
        }
        return true
    }

    func cancel() {
        resolve(with: .failure(CancellationError()))
    }

    func complete(with result: Result<String, Error>) {
        resolve(with: result)
    }

    private func resolve(with result: Result<String, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<String, Error>? in
            switch state {
            case .awaitingContinuation:
                state = .resolved(result)
                return nil
            case .pending(let continuation):
                state = .resolved(result)
                return continuation
            case .resolved:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}

/// 翻訳ワーカーを起こすための合流シグナル。バッファ1件の`AsyncStream`により、
/// ワーカーが処理中に何度sendされても起床要求は1回に合流される。
@MainActor
final class CoalescingTranslationWakeSignal {
    enum SendResult: Equatable {
        case enqueued
        case coalesced
        case terminated
    }

    let stream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init() {
        (stream, signalContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    @discardableResult
    func send() -> SendResult {
        switch signalContinuation.yield(()) {
        case .enqueued:
            return .enqueued
        case .dropped:
            return .coalesced
        case .terminated:
            return .terminated
        @unknown default:
            return .terminated
        }
    }

    func finish() {
        signalContinuation.finish()
    }
}

/// 翻訳方向(日→英 / 英→日)ごとの依頼キューと実行中作業の管理。
/// スケジューリング(`LatestTranslationScheduler`)と起床(`CoalescingTranslationWakeSignal`)を
/// 束ね、final依頼によるlive作業の横取り(preempt)もここで行う。
@MainActor
final class TranslationLane {
    private struct ActiveWork {
        let request: PendingTranslationRequest
        let cancel: () -> Void
    }

    private var scheduler: LatestTranslationScheduler<PendingTranslationRequest>
    private var wakeSignal: CoalescingTranslationWakeSignal?
    private var activeWork: ActiveWork?

    init(finalCapacity: Int) {
        scheduler = LatestTranslationScheduler(finalCapacity: finalCapacity)
    }

    func beginRun() -> AsyncStream<Void> {
        precondition(wakeSignal == nil, "Translation lane already has a consumer")
        let wakeSignal = CoalescingTranslationWakeSignal()
        self.wakeSignal = wakeSignal
        if !scheduler.isEmpty {
            wakeSignal.send()
        }
        return wakeSignal.stream
    }

    func endRun() {
        wakeSignal?.finish()
        wakeSignal = nil
        cancelAll()
    }

    func submit(_ request: PendingTranslationRequest) {
        guard request.isActive else { return }
        _ = scheduler.removeAll { !$0.isActive }
        let result = scheduler.enqueue(request, priority: request.priority)
        if let rejectedFinal = result.rejectedFinal {
            rejectedFinal.complete(with: .failure(LocalTranslationError.queueFull))
            return
        }
        result.supersededLive?.cancel()
        if request.priority == .final {
            preemptActiveLive()
        }
        wakeSignal?.send()
    }

    func takeNext() -> PendingTranslationRequest? {
        while let request = scheduler.next() {
            if request.isActive {
                return request
            }
        }
        return nil
    }

    func beginActiveWork(
        request: PendingTranslationRequest,
        cancel: @escaping () -> Void
    ) {
        precondition(activeWork == nil)
        activeWork = ActiveWork(request: request, cancel: cancel)
    }

    func finishActiveWork(request: PendingTranslationRequest) {
        guard activeWork?.request === request else { return }
        activeWork = nil
    }

    func cancel(_ request: PendingTranslationRequest) {
        _ = scheduler.removeAll { $0 === request }
        guard activeWork?.request === request else { return }
        activeWork?.cancel()
    }

    /// 確定文の翻訳を優先するため、実行中のlive翻訳を中断する。
    private func preemptActiveLive() {
        guard let activeWork, activeWork.request.priority == .live else { return }
        activeWork.request.cancel()
        activeWork.cancel()
    }

    private func cancelAll() {
        let pendingRequests = scheduler.removeAll()
        for request in pendingRequests {
            request.cancel()
        }
        activeWork?.request.cancel()
        activeWork?.cancel()
        activeWork = nil
    }
}
