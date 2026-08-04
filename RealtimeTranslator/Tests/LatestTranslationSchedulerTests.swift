import XCTest
@testable import RealtimeTranslator

final class LatestTranslationSchedulerTests: XCTestCase {
    func testLiveRequestsKeepOnlyLatestItem() {
        // Given: 空の翻訳スケジューラ
        var scheduler = LatestTranslationScheduler<String>()

        // When: 発話途中の仮訳を連続投入する
        let firstSuperseded = scheduler.enqueue("first", priority: .live)
        let secondSuperseded = scheduler.enqueue("latest", priority: .live)

        // Then: 古い仮訳を返し、最新仮訳だけを実行対象にする
        XCTAssertNil(firstSuperseded)
        XCTAssertEqual(secondSuperseded, "first")
        XCTAssertEqual(scheduler.next(), "latest")
        XCTAssertTrue(scheduler.isEmpty)
    }

    func testFinalRequestSupersedesPendingLiveRequest() {
        // Given: 未処理の仮訳があるスケジューラ
        var scheduler = LatestTranslationScheduler<String>()
        _ = scheduler.enqueue("live", priority: .live)

        // When: 確定文を投入する
        let superseded = scheduler.enqueue("final", priority: .final)

        // Then: 仮訳を破棄し、確定文を先に取り出す
        XCTAssertEqual(superseded, "live")
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
}
