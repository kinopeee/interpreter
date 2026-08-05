import XCTest
@testable import RealtimeTranslator

final class DualRealtimeTranslationClientTests: XCTestCase {
    func testSourceConnectionPublishesEveryDeltaForSameItem() async throws {
        // Given: 専用transcriptionを開始したclient
        let sourceTransport = FakeRealtimeWebSocketTransport()
        let englishTransport = FakeRealtimeWebSocketTransport()
        let japaneseTransport = FakeRealtimeWebSocketTransport()
        let dual = makeDual(
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        try await startDual(
            dual,
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        let received = expectation(description: "同一itemの2 deltaを受信")
        let stream = await dual.events
        let collector = Task {
            var deltas: [String] = []
            for await event in stream {
                guard case .inputTranscriptDelta(let delta, _, _) = event.event else {
                    continue
                }
                deltas.append(delta)
                if deltas.count == 2 {
                    received.fulfill()
                    return deltas
                }
            }
            return deltas
        }

        // When: event_idなし・同一item_idの連続deltaを受け取る
        try await sourceTransport.enqueueJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item-1",
            "delta": "それ",
        ])
        try await sourceTransport.enqueueJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item-1",
            "delta": "ぞれ",
        ])
        await fulfillment(of: [received], timeout: 1)

        // Then: item_idで誤って重複排除しない
        let deltas = await collector.value
        XCTAssertEqual(deltas, ["それ", "ぞれ"])
        await dual.forceClose()
    }

    func testUndeterminedLanguageBuffersPrerollUntilEnglishDetected() async throws {
        // Given: 3接続がreadyだが発話言語は未判定
        let sourceTransport = FakeRealtimeWebSocketTransport()
        let englishTransport = FakeRealtimeWebSocketTransport()
        let japaneseTransport = FakeRealtimeWebSocketTransport()
        let dual = makeDual(
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        try await startDual(
            dual,
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )

        // When: 2frame送信後に英語発話と判定する
        let frameA = Data(repeating: 0x11, count: PCM16FramePacketizer.bytesPerFrame)
        let frameB = Data(repeating: 0x22, count: PCM16FramePacketizer.bytesPerFrame)
        try await dual.appendAudioFrame(frameA)
        try await dual.appendAudioFrame(frameB)
        let japaneseBeforeDetection = try decodeAppendPayloads(
            await japaneseTransport.sent
        )
        let englishBeforeDetection = try decodeAppendPayloads(
            await englishTransport.sent
        )
        try await dual.setSpokenLanguage(.english)
        try await waitUntilAppendCount(japaneseTransport, minimum: 2)

        // Then: 判定前は原文のみ。判定後に日本語targetへprerollが届く
        let sourceAppends = try decodeAppendPayloads(await sourceTransport.sent)
        let englishAppends = try decodeAppendPayloads(await englishTransport.sent)
        let japaneseAppends = try decodeAppendPayloads(await japaneseTransport.sent)
        XCTAssertTrue(japaneseBeforeDetection.isEmpty)
        XCTAssertTrue(englishBeforeDetection.isEmpty)
        XCTAssertEqual(sourceAppends, [frameA.base64EncodedString(), frameB.base64EncodedString()])
        XCTAssertTrue(englishAppends.isEmpty)
        XCTAssertEqual(japaneseAppends, sourceAppends)
    }

    func testJapaneseDetectionFlushesPrerollToEnglishOnly() async throws {
        // Given: 未判定中にframeを保持しているdual client
        let sourceTransport = FakeRealtimeWebSocketTransport()
        let englishTransport = FakeRealtimeWebSocketTransport()
        let japaneseTransport = FakeRealtimeWebSocketTransport()
        let dual = makeDual(
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        try await startDual(
            dual,
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        let frameA = Data(repeating: 0x33, count: PCM16FramePacketizer.bytesPerFrame)
        let frameB = Data(repeating: 0x44, count: PCM16FramePacketizer.bytesPerFrame)
        try await dual.appendAudioFrame(frameA)

        // When: 日本語発話と判定後に次frameを送る
        try await dual.setSpokenLanguage(.japanese)
        try await dual.appendAudioFrame(frameB)
        try await waitUntilAppendCount(englishTransport, minimum: 2)

        // Then: prerollと後続frameは英語targetだけへ送られる
        let englishAppends = try decodeAppendPayloads(await englishTransport.sent)
        let japaneseAppends = try decodeAppendPayloads(await japaneseTransport.sent)
        XCTAssertEqual(
            englishAppends,
            [frameA.base64EncodedString(), frameB.base64EncodedString()]
        )
        XCTAssertTrue(japaneseAppends.isEmpty)
    }

    func testSourceAppendContinuesWhenTranslationSendHangs() async throws {
        // Given: 英語targetの送信が長時間停滞するdual
        let sourceTransport = FakeRealtimeWebSocketTransport()
        let englishTransport = FakeRealtimeWebSocketTransport()
        let japaneseTransport = FakeRealtimeWebSocketTransport()
        let dual = makeDual(
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        try await startDual(
            dual,
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        let frameA = Data(repeating: 0x55, count: PCM16FramePacketizer.bytesPerFrame)
        let frameB = Data(repeating: 0x66, count: PCM16FramePacketizer.bytesPerFrame)
        let frameC = Data(repeating: 0x77, count: PCM16FramePacketizer.bytesPerFrame)
        try await dual.appendAudioFrame(frameA)
        try await dual.setSpokenLanguage(.japanese)
        await englishTransport.setSendHangNanoseconds(2_000_000_000)

        // When: 翻訳停滞中でも原文へ連続送信できる
        try await dual.appendAudioFrame(frameB)
        try await dual.appendAudioFrame(frameC)

        // Then: 原文側は翻訳停滞を待たず3frameを受け取る
        let sourceAppends = try decodeAppendPayloads(await sourceTransport.sent)
        XCTAssertEqual(
            sourceAppends,
            [
                frameA.base64EncodedString(),
                frameB.base64EncodedString(),
                frameC.base64EncodedString(),
            ]
        )
        await dual.forceClose()
    }

    func testDedicatedSourceConfigRequestsLiveTranscription() async throws {
        // Given
        let sourceTransport = FakeRealtimeWebSocketTransport()
        let englishTransport = FakeRealtimeWebSocketTransport()
        let japaneseTransport = FakeRealtimeWebSocketTransport()
        let dual = makeDual(
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )

        // When
        try await startDual(
            dual,
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )

        // Then: 専用原文接続だけがgpt-live-transcribeを要求する
        let sourceUpdate = try await firstSessionUpdate(sourceTransport)
        let englishUpdate = try await firstSessionUpdate(englishTransport)
        let japaneseUpdate = try await firstSessionUpdate(japaneseTransport)
        let sourceInput = try XCTUnwrap(
            ((sourceUpdate["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"]
                as? [String: Any]
        )
        let englishInput = try XCTUnwrap(
            ((englishUpdate["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"]
                as? [String: Any]
        )
        let japaneseInput = try XCTUnwrap(
            ((japaneseUpdate["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"]
                as? [String: Any]
        )
        let sourceTranscription = try XCTUnwrap(
            sourceInput["transcription"] as? [String: Any]
        )
        let sourceNoiseReduction = try XCTUnwrap(
            sourceInput["noise_reduction"] as? [String: Any]
        )
        XCTAssertEqual(sourceTranscription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(sourceTranscription["delay"] as? String, "low")
        XCTAssertEqual(
            sourceTranscription["prompt"] as? String,
            RealtimeSourceTranscriptionConnection.transcriptionPrompt
        )
        XCTAssertEqual(
            sourceTranscription["keywords"] as? [String],
            RealtimeSourceTranscriptionConnection.transcriptionKeywords
        )
        XCTAssertEqual(sourceNoiseReduction["type"] as? String, "far_field")
        XCTAssertNil(englishInput["transcription"])
        XCTAssertNil(japaneseInput["transcription"])
    }

    func testOneSidedFailureForceClosesPair() async throws {
        // Given: readyなdual
        let sourceTransport = FakeRealtimeWebSocketTransport()
        let englishTransport = FakeRealtimeWebSocketTransport()
        let japaneseTransport = FakeRealtimeWebSocketTransport()
        let dual = makeDual(
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        try await startDual(
            dual,
            sourceTransport: sourceTransport,
            englishTransport: englishTransport,
            japaneseTransport: japaneseTransport
        )
        let epochBefore = await dual.connectionEpoch

        // When: 原文接続で送信失敗させる
        await sourceTransport.setSendError(RealtimeTranslationError.recoverableTransportFailure("boom"))
        do {
            try await dual.appendAudioFrame(Data(count: PCM16FramePacketizer.bytesPerFrame))
            XCTFail("Expected append failure")
        } catch {
            await dual.forceClose()
        }

        // Then: epochが進み全接続が閉じる
        let epochAfter = await dual.connectionEpoch
        let sourceClose = await sourceTransport.closeCount
        let englishClose = await englishTransport.closeCount
        let japaneseClose = await japaneseTransport.closeCount
        XCTAssertGreaterThan(epochAfter, epochBefore)
        XCTAssertGreaterThanOrEqual(sourceClose, 1)
        XCTAssertGreaterThanOrEqual(englishClose, 1)
        XCTAssertGreaterThanOrEqual(japaneseClose, 1)
    }

    private func makeDual(
        sourceTransport: FakeRealtimeWebSocketTransport,
        englishTransport: FakeRealtimeWebSocketTransport,
        japaneseTransport: FakeRealtimeWebSocketTransport
    ) -> DualRealtimeTranslationClient {
        DualRealtimeTranslationClient(
            sourceConnection: RealtimeSourceTranscriptionConnection(
                transport: sourceTransport,
                safetyIdentifier: "test-safety",
                handshakeTimeoutNanoseconds: 1_000_000_000,
                closeTimeoutNanoseconds: 500_000_000
            ),
            englishConnection: RealtimeTranslationConnection(
                target: .english,
                transport: englishTransport,
                safetyIdentifier: "test-safety",
                sessionUpdateTimeoutNanoseconds: 1_000_000_000,
                closeTimeoutNanoseconds: 500_000_000
            ),
            japaneseConnection: RealtimeTranslationConnection(
                target: .japanese,
                transport: japaneseTransport,
                safetyIdentifier: "test-safety",
                sessionUpdateTimeoutNanoseconds: 1_000_000_000,
                closeTimeoutNanoseconds: 500_000_000
            )
        )
    }

    private func startDual(
        _ dual: DualRealtimeTranslationClient,
        sourceTransport: FakeRealtimeWebSocketTransport,
        englishTransport: FakeRealtimeWebSocketTransport,
        japaneseTransport: FakeRealtimeWebSocketTransport
    ) async throws {
        try await sourceTransport.enqueueJSON(["type": "session.created"])
        try await englishTransport.enqueueJSON(["type": "session.created"])
        try await japaneseTransport.enqueueJSON(["type": "session.created"])

        let startTask = Task {
            try await dual.start(apiKey: "sk-test")
        }

        try await waitUntilSent(sourceTransport, minimum: 1)
        try await waitUntilSent(englishTransport, minimum: 1)
        try await waitUntilSent(japaneseTransport, minimum: 1)
        try await sourceTransport.enqueueJSON(["type": "session.updated"])
        try await englishTransport.enqueueJSON(["type": "session.updated"])
        try await japaneseTransport.enqueueJSON(["type": "session.updated"])
        try await startTask.value
    }

    private func decodeAppendPayloads(_ sent: [Data]) throws -> [String] {
        try sent.compactMap { data in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            guard let type = object["type"] as? String,
                type == "session.input_audio_buffer.append"
                    || type == "input_audio_buffer.append"
            else {
                return nil
            }
            return object["audio"] as? String
        }
    }

    private func firstSessionUpdate(
        _ transport: FakeRealtimeWebSocketTransport
    ) async throws -> [String: Any] {
        let sent = await transport.sent
        for data in sent {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            if object["type"] as? String == "session.update" {
                return object
            }
        }
        XCTFail("session.update not found")
        return [:]
    }

    private func waitUntilSent(
        _ transport: FakeRealtimeWebSocketTransport,
        minimum: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await transport.sent.count >= minimum { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for sent count \(minimum)")
    }

    private func waitUntilAppendCount(
        _ transport: FakeRealtimeWebSocketTransport,
        minimum: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let appends = try decodeAppendPayloads(await transport.sent)
            if appends.count >= minimum { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for append count \(minimum)")
    }
}

extension FakeRealtimeWebSocketTransport {
    func setSendError(_ error: Error?) {
        sendError = error
    }

    func setSendHangNanoseconds(_ nanoseconds: UInt64) {
        sendHangNanoseconds = nanoseconds
    }
}
