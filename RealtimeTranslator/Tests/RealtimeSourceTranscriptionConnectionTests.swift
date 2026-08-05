import XCTest
@testable import RealtimeTranslator

final class RealtimeSourceTranscriptionConnectionTests: XCTestCase {
    func testConnectsTranscriptionEndpointWithLiveModelConfig() async throws {
        // Given: 専用原文transcription接続
        let transport = FakeRealtimeWebSocketTransport()
        let connection = RealtimeSourceTranscriptionConnection(
            transport: transport,
            safetyIdentifier: "safety-id",
            handshakeTimeoutNanoseconds: 1_000_000_000,
            closeTimeoutNanoseconds: 500_000_000
        )
        try await transport.enqueueJSON(["type": "session.created"])
        let startTask = Task {
            try await connection.start(apiKey: "sk-test-source")
        }

        // When: session.update送信後にupdatedを返す
        try await waitUntilSent(transport, minimum: 1)
        try await transport.enqueueJSON(["type": "session.updated"])
        try await startTask.value

        // Then: transcription endpointとgpt-live-transcribe設定を使う
        let url = await transport.lastConnectURL
        let headers = await transport.lastConnectHeaders
        XCTAssertEqual(url, RealtimeSourceTranscriptionConnection.endpointURL)
        XCTAssertEqual(headers["Authorization"], "Bearer sk-test-source")
        XCTAssertEqual(headers["OpenAI-Safety-Identifier"], "safety-id")

        let update = try await firstJSON(ofType: "session.update", from: transport)
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap(
            (session["audio"] as? [String: Any])?["input"] as? [String: Any]
        )
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        let noise = try XCTUnwrap(input["noise_reduction"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertEqual(transcription["languages"] as? [String], ["ja", "en"])
        XCTAssertEqual(noise["type"] as? String, "far_field")
        await connection.forceClose()
    }

    func testEmptyDeltaIsIgnoredWhileNonEmptyDeltaIsPublished() async throws {
        // Given: readyな原文接続
        let transport = FakeRealtimeWebSocketTransport()
        let connection = try await startConnection(transport: transport)
        let received = expectation(description: "非空deltaのみ受信")
        let stream = await connection.events
        let collector = Task {
            var deltas: [String] = []
            for await event in stream {
                guard case .inputTranscriptDelta(let delta, _, _) = event.event else {
                    continue
                }
                deltas.append(delta)
                if deltas.count == 1 {
                    received.fulfill()
                    return deltas
                }
            }
            return deltas
        }

        // When: 空deltaのあと非空deltaを送る
        try await transport.enqueueJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "delta": "",
        ])
        try await transport.enqueueJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "delta": "こんにちは",
        ])
        await fulfillment(of: [received], timeout: 1)

        // Then: 空文字は画面authorityに載せない
        let deltas = await collector.value
        XCTAssertEqual(deltas, ["こんにちは"])
        await connection.forceClose()
    }

    func testCloseGracefullyCommitsAndWaitsForCompleted() async throws {
        // Given: readyな原文接続
        let transport = FakeRealtimeWebSocketTransport()
        let connection = try await startConnection(transport: transport)

        // When: close中にcompletedを返す
        let closeTask = Task {
            try await connection.closeGracefully()
        }
        try await waitUntilSent(transport, minimum: 2)
        try await transport.enqueueJSON([
            "type": "conversation.item.input_audio_transcription.completed",
        ])
        try await closeTask.value

        // Then: commitしてからsocketを閉じる
        let commit = try await firstJSON(ofType: "input_audio_buffer.commit", from: transport)
        XCTAssertEqual(commit["type"] as? String, "input_audio_buffer.commit")
        let closeCount = await transport.closeCount
        XCTAssertGreaterThanOrEqual(closeCount, 1)
    }

    func testAuthenticationFailureIsFatal() async {
        // Given: created直後にauth errorを返すtransport
        let transport = FakeRealtimeWebSocketTransport()
        let connection = RealtimeSourceTranscriptionConnection(
            transport: transport,
            safetyIdentifier: "safety-id",
            handshakeTimeoutNanoseconds: 1_000_000_000,
            closeTimeoutNanoseconds: 500_000_000
        )
        try? await transport.enqueueJSON(["type": "session.created"])
        let startTask = Task {
            try await connection.start(apiKey: "sk-bad")
        }

        // When: session.update後にinvalid_api_keyを返す
        do {
            try await waitUntilSent(transport, minimum: 1)
            try await transport.enqueueJSON([
                "type": "error",
                "error": [
                    "code": "invalid_api_key",
                    "message": "Incorrect API key provided",
                ],
            ])
            try await startTask.value
            XCTFail("Expected authentication failure")
        } catch let error as RealtimeTranslationError {
            // Then: 再接続対象にしないfatal auth失敗になる
            XCTAssertEqual(error, .authenticationFailed)
            XCTAssertFalse(error.isRecoverable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func startConnection(
        transport: FakeRealtimeWebSocketTransport
    ) async throws -> RealtimeSourceTranscriptionConnection {
        let connection = RealtimeSourceTranscriptionConnection(
            transport: transport,
            safetyIdentifier: "safety-id",
            handshakeTimeoutNanoseconds: 1_000_000_000,
            closeTimeoutNanoseconds: 500_000_000
        )
        try await transport.enqueueJSON(["type": "session.created"])
        let startTask = Task {
            try await connection.start(apiKey: "sk-test")
        }
        try await waitUntilSent(transport, minimum: 1)
        try await transport.enqueueJSON(["type": "session.updated"])
        try await startTask.value
        return connection
    }

    private func firstJSON(
        ofType type: String,
        from transport: FakeRealtimeWebSocketTransport
    ) async throws -> [String: Any] {
        let sent = await transport.sent
        for data in sent {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            if object["type"] as? String == type {
                return object
            }
        }
        XCTFail("JSON type \(type) not found")
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
}
