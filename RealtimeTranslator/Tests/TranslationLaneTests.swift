import XCTest
@testable import RealtimeTranslator

@MainActor
final class TranslationLaneTests: XCTestCase {
    func testFinalSubmissionPreemptsActiveLiveWork() async throws {
        // Given: live翻訳が実行中のレーン
        let lane = TranslationLane(finalCapacity: 4)
        _ = lane.beginRun()
        defer { lane.endRun() }

        let live = PendingTranslationRequest(text: "live", priority: .live)
        var cancelHookCount = 0
        lane.beginActiveWork(request: live) {
            cancelHookCount += 1
        }

        // When: 同一レーンへfinal依頼を投入する
        let final = PendingTranslationRequest(text: "final", priority: .final)
        let finalTask = Task { @MainActor in
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                XCTAssertTrue(final.install(continuation))
                lane.submit(final)
            }
        }
        let next = try XCTUnwrap(lane.takeNext())
        XCTAssertTrue(next === final)
        next.complete(with: .success("final translation"))
        let translated = try await finalTask.value

        // Then: 実行中liveを横取りし、finalを優先して取り出せる
        XCTAssertEqual(cancelHookCount, 1)
        XCTAssertFalse(live.isActive)
        XCTAssertEqual(translated, "final translation")
    }

    func testLiveSubmissionDoesNotPreemptActiveLiveWork() {
        // Given: live翻訳が実行中のレーン
        let lane = TranslationLane(finalCapacity: 4)
        _ = lane.beginRun()
        defer { lane.endRun() }

        let activeLive = PendingTranslationRequest(text: "active", priority: .live)
        var cancelHookCount = 0
        lane.beginActiveWork(request: activeLive) {
            cancelHookCount += 1
        }

        // When: 新しいlive依頼を投入する
        let newerLive = PendingTranslationRequest(text: "newer", priority: .live)
        lane.submit(newerLive)

        // Then: 実行中liveは横取りせず、新しいliveだけをキューに載せる
        XCTAssertEqual(cancelHookCount, 0)
        XCTAssertTrue(activeLive.isActive)
        XCTAssertEqual(lane.takeNext()?.text, "newer")
        XCTAssertNil(lane.takeNext())
    }
}
