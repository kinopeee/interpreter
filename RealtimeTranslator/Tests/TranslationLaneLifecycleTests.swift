import XCTest
@testable import RealtimeTranslator

@MainActor
final class TranslationLaneLifecycleTests: XCTestCase {
    func testBeginRunWakesAlreadyQueuedFinalRequest() async {
        // Given: consumer起動前に確定翻訳が待機しているレーン
        let lane = TranslationLane(finalCapacity: 4)
        let request = PendingTranslationRequest(text: "queued", priority: .final)
        lane.submit(request)
        let stream = lane.beginRun()
        defer { lane.endRun() }

        // When: 起動直後の起床通知を待つ
        let wake = expectation(description: "queued work wakes the consumer")
        Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            wake.fulfill()
        }

        // Then: 既存キューを見逃さず、consumerを起こして取り出せる
        await fulfillment(of: [wake], timeout: 1)
        XCTAssertTrue(lane.takeNext() === request)
        request.cancel()
    }

    func testTakeNextSkipsCancelledRequestsAndReturnsNextActive() {
        // Given: 先頭の確定依頼が取消済みで、次の依頼は有効なレーン
        let lane = TranslationLane(finalCapacity: 4)
        let cancelled = PendingTranslationRequest(text: "cancelled", priority: .final)
        let active = PendingTranslationRequest(text: "active", priority: .final)
        lane.submit(cancelled)
        lane.submit(active)
        cancelled.cancel()

        // When: 次の処理対象を取り出す
        let next = lane.takeNext()

        // Then: 取消済みを飛ばし、有効な確定依頼だけを返す
        XCTAssertTrue(next === active)
        XCTAssertNil(lane.takeNext())
        active.cancel()
    }

    func testEndRunResolvesInstalledContinuationAsCancellation() async {
        // Given: continuation待ちの確定依頼が残っているレーン
        let lane = TranslationLane(finalCapacity: 4)
        let request = PendingTranslationRequest(text: "queued", priority: .final)
        _ = lane.beginRun()
        lane.submit(request)
        let waiting = Task {
            try await withCheckedThrowingContinuation { continuation in
                _ = request.install(continuation)
            }
        }

        // When: レーンの実行を終了する
        lane.endRun()

        // Then: 待ち中の依頼をCancellationErrorで解放し、キューを空にする
        do {
            _ = try await waiting.value
            XCTFail("endRun後の依頼は成功してはいけません")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(lane.takeNext())
    }

    func testInactiveRequestIsNotEnqueued() {
        // Given: 投入前に取り消された翻訳依頼
        let lane = TranslationLane(finalCapacity: 4)
        let request = PendingTranslationRequest(text: "inactive", priority: .final)
        request.cancel()

        // When: 無効な依頼をレーンへ投入する
        lane.submit(request)

        // Then: キューへ積まず、後続の取り出し対象にしない
        XCTAssertNil(lane.takeNext())
    }

    func testCancelPendingRequestDoesNotInvokeActiveCancel() {
        // Given: 実行中の確定依頼と、別の待機確定依頼があるレーン
        let lane = TranslationLane(finalCapacity: 4)
        let activeFinal = PendingTranslationRequest(text: "active", priority: .final)
        let pendingFinal = PendingTranslationRequest(text: "pending", priority: .final)
        var activeCancelCount = 0
        lane.submit(activeFinal)
        XCTAssertTrue(lane.takeNext() === activeFinal)
        lane.beginActiveWork(request: activeFinal) {
            activeCancelCount += 1
        }
        lane.submit(pendingFinal)

        // When: 待機中の確定依頼だけを取り消す
        lane.cancel(pendingFinal)

        // Then: 実行中作業のcancelは呼ばず、待機依頼だけをキューから外す
        XCTAssertEqual(activeCancelCount, 0)
        XCTAssertNil(lane.takeNext())
        lane.finishActiveWork(request: activeFinal)
        activeFinal.cancel()
    }

    func testMismatchedFinishLeavesActiveWorkCancellable() {
        // Given: live作業中のレーン
        let lane = TranslationLane(finalCapacity: 4)
        let live = PendingTranslationRequest(text: "live", priority: .live)
        let other = PendingTranslationRequest(text: "other", priority: .live)
        var activeCancelCount = 0
        lane.beginActiveWork(request: live) {
            activeCancelCount += 1
        }

        // When: 別依頼の完了通知のあと、実行中liveを取り消す
        lane.finishActiveWork(request: other)
        lane.cancel(live)

        // Then: 不一致の完了ではactiveを外さず、取消コールバックを実行できる
        XCTAssertEqual(activeCancelCount, 1)
    }

    func testWakeSignalSendAfterFinishIsTerminated() {
        // Given: 終了済みの起床シグナル
        let signal = CoalescingTranslationWakeSignal()
        signal.finish()

        // When: 終了後に起床を送る
        let result = signal.send()

        // Then: 新しい通知は積まず、終了済みとして扱う
        XCTAssertEqual(result, .terminated)
    }
}
