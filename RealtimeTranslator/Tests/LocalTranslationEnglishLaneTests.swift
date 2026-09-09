import XCTest
@testable import RealtimeTranslator

@MainActor
final class LocalTranslationEnglishLaneTests: XCTestCase {
    func testEnglishLiveAndFinalRequestsRouteToIndependentLanes() async throws {
        // Given: live/finalそれぞれ別driverで動く英日翻訳サービス
        let service = LocalTranslationService()
        let liveDriver = RecordingTranslationSession()
        let finalDriver = RecordingTranslationSession()
        liveDriver.translations["live"] = "ライブ訳"
        finalDriver.translations["final"] = "確定訳"
        let liveRunTask = Task { @MainActor in
            await service.runEnglishToJapaneseLive(driver: liveDriver)
        }
        let finalRunTask = Task { @MainActor in
            await service.runEnglishToJapaneseFinal(driver: finalDriver)
        }
        defer {
            liveRunTask.cancel()
            finalRunTask.cancel()
        }
        await liveDriver.waitUntilPrepareCallCount(1)
        await finalDriver.waitUntilPrepareCallCount(1)

        // When: 英語原文をliveとfinalへ投入する
        let liveTranslation = try await service.translate(
            "live",
            from: .english,
            priority: .live
        )
        let finalTranslation = try await service.translate(
            "final",
            from: .english,
            priority: .final
        )

        // Then: 各優先度が英日レーンの自分のdriverだけへ届く
        XCTAssertEqual(liveTranslation, "ライブ訳")
        XCTAssertEqual(finalTranslation, "確定訳")
        XCTAssertEqual(liveDriver.translationCalls, ["live"])
        XCTAssertEqual(finalDriver.translationCalls, ["final"])
        liveRunTask.cancel()
        finalRunTask.cancel()
        await liveRunTask.value
        await finalRunTask.value
    }

    func testEnglishFinalReadyFlagIgnoresLiveLanePreparation() async throws {
        // Given: 英日liveレーンだけ準備済みで、finalレーンは未準備のサービス
        let service = LocalTranslationService()
        let liveDriver = RecordingTranslationSession()
        let liveRunTask = Task { @MainActor in
            await service.runEnglishToJapaneseLive(driver: liveDriver)
        }
        defer { liveRunTask.cancel() }
        await liveDriver.waitUntilPrepareCallCount(1)

        // When: liveレーンの準備完了を待つ
        // Then: readyフラグは英日finalセッションの状態だけを表す
        XCTAssertFalse(service.isEnglishToJapaneseReady)
        liveRunTask.cancel()
        await liveRunTask.value
    }

    func testTranslateTrimsSurroundingWhitespaceBeforeQueueing() async throws {
        // Given: 英日finalレーンが準備済みの翻訳サービス
        let service = LocalTranslationService()
        let driver = RecordingTranslationSession()
        driver.translations["Hello there"] = "こんにちは"
        let runTask = Task { @MainActor in
            await service.runEnglishToJapaneseFinal(driver: driver)
        }
        defer { runTask.cancel() }
        await driver.waitUntilPrepareCallCount(1)

        // When: 前後に空白のある英語原文を翻訳する
        let translated = try await service.translate(
            "  Hello there  ",
            from: .english,
            priority: .final
        )

        // Then: 空白を除いた本文だけを翻訳器へ渡し、空キュー投入はしない
        XCTAssertEqual(translated, "こんにちは")
        XCTAssertEqual(driver.translationCalls, ["Hello there"])
        runTask.cancel()
        await runTask.value
    }
}

@MainActor
private final class RecordingTranslationSession: LocalTranslationSessionDriving {
    var translations: [String: String] = [:]
    private(set) var prepareCallCount = 0
    private(set) var translationCalls: [String] = []
    private var prepareWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func prepare() async throws {
        prepareCallCount += 1
        let waiters = prepareWaiters.removeValue(forKey: prepareCallCount) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func translate(_ text: String) async throws -> String {
        translationCalls.append(text)
        return translations[text] ?? "Translated: \(text)"
    }

    func waitUntilPrepareCallCount(_ count: Int) async {
        guard prepareCallCount < count else { return }
        await withCheckedContinuation { continuation in
            prepareWaiters[count, default: []].append(continuation)
        }
    }
}
