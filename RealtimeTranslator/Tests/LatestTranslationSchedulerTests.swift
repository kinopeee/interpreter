import XCTest
@testable import RealtimeTranslator

final class LatestTranslationSchedulerTests: XCTestCase {
    func testLiveRequestsKeepOnlyLatestItem() {
        // Given: 空の翻訳スケジューラ
        var scheduler = LatestTranslationScheduler<String>()

        // When: 発話途中の仮訳を連続投入する
        let firstResult = scheduler.enqueue("first", priority: .live)
        let secondResult = scheduler.enqueue("latest", priority: .live)

        // Then: 古い仮訳を返し、最新仮訳だけを実行対象にする
        XCTAssertNil(firstResult.supersededLive)
        XCTAssertNil(firstResult.rejectedFinal)
        XCTAssertEqual(secondResult.supersededLive, "first")
        XCTAssertNil(secondResult.rejectedFinal)
        XCTAssertEqual(scheduler.next(), "latest")
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testFinalRequestSupersedesPendingLiveRequest() {
        // Given: 未処理の仮訳があるスケジューラ
        var scheduler = LatestTranslationScheduler<String>()
        _ = scheduler.enqueue("live", priority: .live)

        // When: 確定文を投入する
        let result = scheduler.enqueue("final", priority: .final)

        // Then: 仮訳を破棄し、確定文を先に取り出す
        XCTAssertEqual(result.supersededLive, "live")
        XCTAssertNil(result.rejectedFinal)
        XCTAssertEqual(scheduler.next(), "final")
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testFinalRequestHasPriorityOverNewerLiveRequest() {
        // Given: 確定文が待機中のスケジューラ
        var scheduler = LatestTranslationScheduler<String>()
        _ = scheduler.enqueue("final", priority: .final)

        // When: 次の発話の仮訳が届く
        _ = scheduler.enqueue("next live", priority: .live)

        // Then: 確定文を先に処理してから最新仮訳を処理する
        XCTAssertEqual(scheduler.next(), "final")
        XCTAssertEqual(scheduler.next(), "next live")
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testFinalQueueAcceptsItemsUpToCapacity() {
        // Given: 確定文を2件まで保持できる翻訳スケジューラ
        var scheduler = LatestTranslationScheduler<String>(finalCapacity: 2)

        // When: 上限ちょうどまで確定文を投入する
        let firstResult = scheduler.enqueue("first", priority: .final)
        let secondResult = scheduler.enqueue("second", priority: .final)

        // Then: 2件を受け付け、FIFO順で取り出せる
        XCTAssertNil(firstResult.rejectedFinal)
        XCTAssertNil(secondResult.rejectedFinal)
        XCTAssertEqual(scheduler.pendingFinalCount, 2)
        XCTAssertEqual(scheduler.next(), "first")
        XCTAssertEqual(scheduler.next(), "second")
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testFinalQueueRejectsItemBeyondCapacity() {
        // Given: 確定文を1件だけ保持でき、すでに上限へ達した翻訳スケジューラ
        var scheduler = LatestTranslationScheduler<String>(finalCapacity: 1)
        _ = scheduler.enqueue("accepted", priority: .final)

        // When: 上限を超える確定文を投入する
        let result = scheduler.enqueue("rejected", priority: .final)

        // Then: 新しい確定文を明示的に拒否し、受付済みの順序を維持する
        XCTAssertEqual(result.rejectedFinal, "rejected")
        XCTAssertEqual(scheduler.pendingFinalCount, 1)
        XCTAssertEqual(scheduler.next(), "accepted")
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testRejectedFinalDoesNotDiscardPendingLiveRequest() {
        // Given: 確定文キューが上限で、次の暫定訳も待機しているスケジューラ
        var scheduler = LatestTranslationScheduler<String>(finalCapacity: 1)
        _ = scheduler.enqueue("accepted final", priority: .final)
        _ = scheduler.enqueue("pending live", priority: .live)

        // When: 上限を超える別の確定文を投入する
        let result = scheduler.enqueue("rejected final", priority: .final)

        // Then: 新しい確定文だけを拒否し、既存finalとliveの順序を維持する
        XCTAssertNil(result.supersededLive)
        XCTAssertEqual(result.rejectedFinal, "rejected final")
        XCTAssertEqual(scheduler.next(), "accepted final")
        XCTAssertEqual(scheduler.next(), "pending live")
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testRemovingCancelledFinalFreesCapacity() {
        // Given: 確定文キューが上限へ達した翻訳スケジューラ
        var scheduler = LatestTranslationScheduler<String>(finalCapacity: 1)
        _ = scheduler.enqueue("cancelled", priority: .final)

        // When: 取消済み項目を除去して別の確定文を投入する
        let removed = scheduler.removeAll { $0 == "cancelled" }
        let result = scheduler.enqueue("replacement", priority: .final)

        // Then: 取消済み項目が容量を占有せず、新しい確定文を受け付ける
        XCTAssertEqual(removed, ["cancelled"])
        XCTAssertNil(result.rejectedFinal)
        XCTAssertEqual(scheduler.pendingFinalCount, 1)
        XCTAssertEqual(scheduler.next(), "replacement")
    }
}
