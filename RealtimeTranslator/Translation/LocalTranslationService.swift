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

enum LocalTranslationPriority: Sendable {
    case live
    case final
}

struct TranslationSchedulerEnqueueResult<Item> {
    let supersededLive: Item?
    let rejectedFinal: Item?
}

struct LatestTranslationScheduler<Item> {
    private let finalCapacity: Int
    private var finalItems: [Item] = []
    private var liveItem: Item?

    init(finalCapacity: Int = 32) {
        precondition(finalCapacity > 0)
        self.finalCapacity = finalCapacity
    }

    var isEmpty: Bool {
        finalItems.isEmpty && liveItem == nil
    }

    var pendingFinalCount: Int {
        finalItems.count
    }

    mutating func enqueue(
        _ item: Item,
        priority: LocalTranslationPriority
    ) -> TranslationSchedulerEnqueueResult<Item> {
        switch priority {
        case .live:
            let superseded = liveItem
            liveItem = item
            return TranslationSchedulerEnqueueResult(
                supersededLive: superseded,
                rejectedFinal: nil
            )
        case .final:
            guard finalItems.count < finalCapacity else {
                return TranslationSchedulerEnqueueResult(
                    supersededLive: nil,
                    rejectedFinal: item
                )
            }
            let superseded = liveItem
            liveItem = nil
            finalItems.append(item)
            return TranslationSchedulerEnqueueResult(
                supersededLive: superseded,
                rejectedFinal: nil
            )
        }
    }

    mutating func next() -> Item? {
        if !finalItems.isEmpty {
            return finalItems.removeFirst()
        }
        defer { liveItem = nil }
        return liveItem
    }

    mutating func removeAll(where shouldRemove: (Item) -> Bool) -> [Item] {
        var removed: [Item] = []
        if let liveItem, shouldRemove(liveItem) {
            removed.append(liveItem)
            self.liveItem = nil
        }

        var retainedFinalItems: [Item] = []
        retainedFinalItems.reserveCapacity(finalItems.count)
        for item in finalItems {
            if shouldRemove(item) {
                removed.append(item)
            } else {
                retainedFinalItems.append(item)
            }
        }
        finalItems = retainedFinalItems
        return removed
    }

    mutating func removeAll() -> [Item] {
        var removed = finalItems
        if let liveItem {
            removed.append(liveItem)
        }
        finalItems.removeAll(keepingCapacity: true)
        liveItem = nil
        return removed
    }
}

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

        signalLoop: for await _ in signals {
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
                            break signalLoop
                        }
                        continue
                    }
                }

                await translate(request, driver: driver, lane: lane)
                if Task.isCancelled {
                    break signalLoop
                }
            }
        }
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
