import Foundation
import os
import XCTest
@testable import RealtimeTranslator

@MainActor
final class LocalTranslationServiceTests: XCTestCase {
    func testLiveAndFinalRequestsRouteToIndependentLanes() async throws {
        // Given: live/finalそれぞれ別driverで動く日英翻訳サービス
        let service = LocalTranslationService()
        let liveDriver = ControlledTranslationSession()
        let finalDriver = ControlledTranslationSession()
        liveDriver.translations["live"] = "live translation"
        finalDriver.translations["final"] = "final translation"
        let liveRunTask = Task { @MainActor in
            await service.runJapaneseToEnglishLive(driver: liveDriver)
        }
        let finalRunTask = Task { @MainActor in
            await service.runJapaneseToEnglishFinal(driver: finalDriver)
        }
        defer {
            liveRunTask.cancel()
            finalRunTask.cancel()
        }
        await liveDriver.waitUntilPrepareCallCount(1)
        await finalDriver.waitUntilPrepareCallCount(1)

        // When: 同じ方向へliveとfinalを投入する
        let liveTranslation = try await service.translate(
            "live",
            from: .japanese,
            priority: .live
        )
        let finalTranslation = try await service.translate(
            "final",
            from: .japanese,
            priority: .final
        )

        // Then: 各優先度が自分のレーン(driver)だけへ届く
        XCTAssertEqual(liveTranslation, "live translation")
        XCTAssertEqual(finalTranslation, "final translation")
        XCTAssertEqual(liveDriver.translationCalls, ["live"])
        XCTAssertEqual(finalDriver.translationCalls, ["final"])
        liveRunTask.cancel()
        finalRunTask.cancel()
        await liveRunTask.value
        await finalRunTask.value
    }

    func testFinalProceedsWhileLiveTranslationIsInFlight() async throws {
        // Given: live翻訳が完了待ちでブロックされている独立レーン構成
        let service = LocalTranslationService()
        let liveDriver = ControlledTranslationSession()
        let finalDriver = ControlledTranslationSession()
        let liveGate = ControlledTranslationGate(
            cancellationResult: .success("stale live translation")
        )
        liveDriver.translationGates["live"] = liveGate
        finalDriver.translations["final"] = "final translation"
        let liveRunTask = Task { @MainActor in
            await service.runJapaneseToEnglishLive(driver: liveDriver)
        }
        let finalRunTask = Task { @MainActor in
            await service.runJapaneseToEnglishFinal(driver: finalDriver)
        }
        defer {
            liveRunTask.cancel()
            finalRunTask.cancel()
        }
        await liveDriver.waitUntilPrepareCallCount(1)
        await finalDriver.waitUntilPrepareCallCount(1)
        let liveTask = Task { @MainActor in
            try await service.translate(
                "live",
                from: .japanese,
                priority: .live
            )
        }
        await liveDriver.waitUntilTranslationStarted("live")

        // When: live実行中に確定文を投入する
        let finalTranslation = try await service.translate(
            "final",
            from: .japanese,
            priority: .final
        )

        // Then: finalはliveを待たず完了し、live作業も取り消さない
        XCTAssertEqual(finalTranslation, "final translation")
        XCTAssertEqual(finalDriver.translationCalls, ["final"])
        XCTAssertEqual(liveGate.cancellationCount, 0)
        XCTAssertFalse(liveTask.isCancelled)
        liveRunTask.cancel()
        finalRunTask.cancel()
        liveTask.cancel()
        await liveRunTask.value
        await finalRunTask.value
        _ = await liveTask.result
    }

    func testPreparationFailureRetriesOnLaterRequests() async throws {
        // Given: 起動時と最初の要求で準備に失敗し、次の要求で回復するfinal session
        let service = LocalTranslationService()
        let driver = ControlledTranslationSession(
            prepareResults: [
                .failure(ControlledTranslationError.preparationFailed),
                .failure(ControlledTranslationError.preparationFailed),
                .success(())
            ]
        )
        driver.translations["second"] = "translated second"
        let runTask = Task { @MainActor in
            await service.runJapaneseToEnglishFinal(driver: driver)
        }
        defer { runTask.cancel() }
        await driver.waitUntilPrepareCallCount(1)
        XCTAssertFalse(service.isJapaneseToEnglishReady)

        // When: 失敗後に2件の翻訳要求を順番に送る
        do {
            _ = try await service.translate(
                "first",
                from: .japanese,
                priority: .final
            )
            XCTFail("最初の要求は準備エラーを返す必要があります")
        } catch let error as ControlledTranslationError {
            XCTAssertEqual(error, .preparationFailed)
            XCTAssertEqual(error.errorDescription, "translation preparation failed")
        }
        let translated = try await service.translate(
            "second",
            from: .japanese,
            priority: .final
        )

        // Then: 準備エラーを固定せず3回目の準備で翻訳を再開する
        XCTAssertEqual(translated, "translated second")
        XCTAssertEqual(driver.prepareCallCount, 3)
        XCTAssertEqual(driver.translationCalls, ["second"])
        XCTAssertTrue(service.isJapaneseToEnglishReady)
        runTask.cancel()
        await runTask.value
    }

    func testFinalReadyFlagIgnoresLiveLanePreparation() async throws {
        // Given: liveレーンだけ準備済みで、finalレーンは未準備のサービス
        let service = LocalTranslationService()
        let liveDriver = ControlledTranslationSession()
        let liveRunTask = Task { @MainActor in
            await service.runJapaneseToEnglishLive(driver: liveDriver)
        }
        defer { liveRunTask.cancel() }
        await liveDriver.waitUntilPrepareCallCount(1)

        // When: liveレーンの準備完了を待つ
        // Then: readyフラグはfinalセッションの状態だけを表す
        XCTAssertFalse(service.isJapaneseToEnglishReady)
        liveRunTask.cancel()
        await liveRunTask.value
    }

    func testFinalQueueOverflowReturnsExplicitError() async {
        // Given: 確定文を1件だけ保持でき、すでに上限へ達したレーン
        let lane = TranslationLane(finalCapacity: 1)
        let accepted = PendingTranslationRequest(text: "accepted", priority: .final)
        lane.submit(accepted)
        let rejected = PendingTranslationRequest(text: "rejected", priority: .final)

        // When: 上限を超える確定文を投入してcontinuationを登録する
        lane.submit(rejected)

        // Then: queueFullの型と日本語メッセージを返す
        do {
            let _: String = try await withCheckedThrowingContinuation {
                continuation in
                let installed = rejected.install(continuation)
                if installed {
                    rejected.cancel()
                }
                XCTAssertFalse(installed)
            }
            XCTFail("上限超過はqueueFullを返す必要があります")
        } catch let error as LocalTranslationError {
            XCTAssertEqual(error, .queueFull)
            XCTAssertEqual(
                error.errorDescription,
                "ローカル翻訳の待機件数が上限に達しました"
            )
        } catch {
            XCTFail("想定外のエラー型です: \(type(of: error))")
        }
        accepted.cancel()
    }

    func testCancelledFinalRequestFreesQueueCapacity() {
        // Given: 取消済み確定文が上限1件のレーンを占有している
        let lane = TranslationLane(finalCapacity: 1)
        let cancelled = PendingTranslationRequest(text: "cancelled", priority: .final)
        lane.submit(cancelled)
        cancelled.cancel()
        let replacement = PendingTranslationRequest(
            text: "replacement",
            priority: .final
        )

        // When: 次の確定文を投入する
        lane.submit(replacement)

        // Then: 取消済み要求を除去し、新しい確定文を処理対象にする
        XCTAssertTrue(lane.takeNext() === replacement)
        replacement.cancel()
    }

    func testWakeSignalCoalescesPendingNotifications() async {
        // Given: consumerがまだ通知を取得していないwake signal
        let signal = CoalescingTranslationWakeSignal()

        // When: 通知を2回連続で送る
        let firstResult = signal.send()
        let secondResult = signal.send()

        // Then: 1件だけをbufferへ保持し、2件目を合流する
        XCTAssertEqual(firstResult, .enqueued)
        XCTAssertEqual(secondResult, .coalesced)
        var iterator = signal.stream.makeAsyncIterator()
        let notification: Void? = await iterator.next()
        XCTAssertNotNil(notification)
        signal.finish()
        let end: Void? = await iterator.next()
        XCTAssertNil(end)
    }

    func testCancellationBeforeContinuationInstallationResolvesOnce() async {
        // Given: continuation登録前に取り消された翻訳要求
        let request = PendingTranslationRequest(text: "cancelled", priority: .live)
        request.cancel()

        // When: continuationを後から登録し、さらに遅い成功完了を通知する
        do {
            let _: String = try await withCheckedThrowingContinuation {
                continuation in
                XCTAssertFalse(request.install(continuation))
                request.complete(with: .success("late success"))
                request.cancel()
            }
            XCTFail("取消済み要求は成功してはいけません")
        } catch {
            // Then: CancellationErrorを一度だけ返し、後続完了を無視する
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}

private enum ControlledTranslationError: Error, LocalizedError, Equatable {
    case preparationFailed

    var errorDescription: String? {
        switch self {
        case .preparationFailed:
            return "translation preparation failed"
        }
    }
}

@MainActor
private final class ControlledTranslationSession: LocalTranslationSessionDriving {
    var translations: [String: String] = [:]
    var translationGates: [String: ControlledTranslationGate] = [:]
    var preparationGates: [Int: ControlledTranslationGate] = [:]
    private(set) var prepareCallCount = 0
    private(set) var translationCalls: [String] = []

    private var prepareResults: [Result<Void, Error>]
    private var prepareWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var translationWaiters:
        [String: [CheckedContinuation<Void, Never>]] = [:]

    init(prepareResults: [Result<Void, Error>] = [.success(())]) {
        self.prepareResults = prepareResults
    }

    func prepare() async throws {
        prepareCallCount += 1
        let waiters = prepareWaiters.removeValue(forKey: prepareCallCount) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        if let gate = preparationGates[prepareCallCount] {
            _ = try await gate.wait()
            return
        }

        let result = prepareResults.isEmpty
            ? Result<Void, Error>.success(())
            : prepareResults.removeFirst()
        try result.get()
    }

    func translate(_ text: String) async throws -> String {
        translationCalls.append(text)
        let waiters = translationWaiters.removeValue(forKey: text) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        if let gate = translationGates[text] {
            return try await gate.wait()
        }
        return translations[text] ?? "Translated: \(text)"
    }

    func waitUntilPrepareCallCount(_ count: Int) async {
        guard prepareCallCount < count else { return }
        await withCheckedContinuation { continuation in
            prepareWaiters[count, default: []].append(continuation)
        }
    }

    func waitUntilTranslationStarted(_ text: String) async {
        guard !translationCalls.contains(text) else { return }
        await withCheckedContinuation { continuation in
            translationWaiters[text, default: []].append(continuation)
        }
    }
}

private final class ControlledTranslationGate: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, Error>?
        var terminalResult: Result<String, Error>?
        var cancellationCount = 0
    }

    private let cancellationResult: Result<String, Error>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(cancellationResult: Result<String, Error>) {
        self.cancellationResult = cancellationResult
    }

    var cancellationCount: Int {
        state.withLock { $0.cancellationCount }
    }

    func wait() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let terminalResult = state.withLock {
                    state -> Result<String, Error>? in
                    if let terminalResult = state.terminalResult {
                        return terminalResult
                    }
                    precondition(state.continuation == nil)
                    state.continuation = continuation
                    return nil
                }
                if let terminalResult {
                    continuation.resume(with: terminalResult)
                }
            }
        } onCancel: {
            let continuation = self.state.withLock {
                state -> CheckedContinuation<String, Error>? in
                state.cancellationCount += 1
                guard state.terminalResult == nil else { return nil }
                state.terminalResult = self.cancellationResult
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: self.cancellationResult)
        }
    }
}
