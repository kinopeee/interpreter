import XCTest
@testable import RealtimeTranslator

@MainActor
final class InterpretationSessionLifecycleGuardTests: XCTestCase {
    func testConnectingStateIgnoresVolatileAndFinalTranscription() async {
        // Given: 音声認識の開始処理が完了していないセッション
        let speechService = FakeSpeechRecognitionService()
        speechService.suspendsStart = true
        let translationService = FakeTranslationService()
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        let startTask = Task { await session.start() }
        await speechService.waitUntilStartCalled()

        // When: connecting中に暫定結果と確定結果が届き、その後開始が完了する
        speechService.emit(text: "開始前の暫定", language: .japanese, isFinal: false)
        speechService.emit(text: "開始前の確定", language: .japanese, isFinal: true)
        speechService.resumeStart()
        await startTask.value

        // Then: 開始前の認識は捨て、listeningへ進んでも字幕へ載せない
        XCTAssertEqual(session.state, .listening)
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "開始前の暫定" }
        )
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "開始前の確定" }
        )
        XCTAssertTrue(translationService.liveRequests.isEmpty)
        XCTAssertTrue(translationService.finalRequests.isEmpty)
        await session.stop()
    }

    func testIdleStateIgnoresLateTranscriptionAfterStop() async {
        // Given: 確定字幕を残して停止したセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["完了文。"] = "Completed sentence"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "完了文", language: .japanese, isFinal: true)
        await delegate.waitUntilCurrentTranslation("Completed sentence")
        await session.stop()

        // When: idleへ戻った後に遅延の認識結果が届く
        speechService.emit(text: "停止後の文", language: .japanese, isFinal: true)

        // Then: 停止後の原文で確定字幕を上書きしない
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(delegate.lastSnapshot?.current.sourceText, "完了文")
        XCTAssertEqual(delegate.lastSnapshot?.current.translatedText, "Completed sentence")
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "停止後の文" }
        )
        XCTAssertEqual(translationService.finalRequests, ["完了文。"])
    }

    func testSpeechFailureDuringConnectingEntersError() async {
        // Given: 音声認識の開始処理が完了していないセッション
        let speechService = FakeSpeechRecognitionService()
        speechService.suspendsStart = true
        let translationService = FakeTranslationService()
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        let startTask = Task { await session.start() }
        await speechService.waitUntilStartCalled()

        // When: connecting中に音声認識パイプラインが失敗する
        speechService.emitFailure(LocalSpeechRecognitionError.speechTranscriberUnavailable)
        await startTask.value
        await delegate.waitUntilMessage("このMacではローカル音声認識を利用できません")

        // Then: listeningへ進まず、停止後に型付きエラーへ遷移する
        XCTAssertEqual(session.state, .error)
        XCTAssertFalse(delegate.states.contains(.listening))
        XCTAssertEqual(
            delegate.messages,
            ["このMacではローカル音声認識を利用できません"]
        )
    }

    func testRapidVolatileUpdatesRenderOnlyTheLatestPendingSource() async {
        // Given: 発話途中の原文が短時間に連続更新されるセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()

        // When: 同一ターンで暫定原文を3回更新する
        speechService.emit(text: "あ", language: .japanese, isFinal: false)
        speechService.emit(text: "あい", language: .japanese, isFinal: false)
        speechService.emit(text: "あいう", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentSource("あいう")

        // Then: 中間の短い原文を画面へ出さず、最新のpendingだけを描画する
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "あ" }
        )
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "あい" }
        )
        XCTAssertEqual(delegate.lastSnapshot?.current.sourceText, "あいう")
        await session.stop()
    }

    func testFinalTranscriptionCancelsUnrenderedVolatile() async throws {
        // Given: 録音中のセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["完成した文。"] = "A finished sentence"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()

        // When: 未描画の暫定原文の直後に確定原文が届く
        speechService.emit(text: "途中", language: .japanese, isFinal: false)
        speechService.emit(text: "完成した文", language: .japanese, isFinal: true)
        await delegate.waitUntilCurrentTranslation("A finished sentence")

        // Then: 未描画の暫定原文をフラッシュせず、確定文だけを翻訳する
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "途中" }
        )
        XCTAssertEqual(delegate.lastSnapshot?.current.sourceText, "完成した文")
        XCTAssertEqual(delegate.lastSnapshot?.current.translatedText, "A finished sentence")
        XCTAssertEqual(translationService.finalRequests, ["完成した文。"])
        XCTAssertFalse(translationService.liveRequests.contains("途中"))
        await session.stop()
    }
}

@MainActor
private final class FakeSpeechRecognitionService: LocalSpeechRecognitionServicing {
    weak var delegate: LocalSpeechRecognitionServiceDelegate?

    var suspendsStart = false
    private(set) var startCallCount = 0
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func start() async throws {
        startCallCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard suspendsStart else { return }

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func stop() async {
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: CancellationError())
        }
    }

    func emit(text: String, language: SpokenLanguage, isFinal: Bool) {
        delegate?.localSpeechRecognitionService(
            didUpdate: text,
            language: language,
            isFinal: isFinal
        )
    }

    func emitFailure(_ error: Error) {
        delegate?.localSpeechRecognitionService(didFail: error)
    }

    func waitUntilStartCalled() async {
        guard startCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: ())
    }
}

@MainActor
private final class FakeTranslationService: LocalTranslationServicing {
    var translations: [String: String] = [:]
    private(set) var finalRequests: [String] = []
    private(set) var liveRequests: [String] = []

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        switch priority {
        case .live:
            liveRequests.append(text)
            return translations[text] ?? "Translated: \(text)"
        case .final:
            finalRequests.append(text)
            return translations[text] ?? "Translated: \(text)"
        }
    }
}

@MainActor
private final class InterpretationSessionDelegateSpy: InterpretationSessionDelegate {
    private(set) var states: [TranslationState] = []
    private(set) var snapshots: [SubtitleSnapshot] = []
    private(set) var messages: [String] = []
    private var currentSourceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var currentTranslationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var messageWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    var lastSnapshot: SubtitleSnapshot? {
        snapshots.last
    }

    func waitUntilCurrentSource(_ sourceText: String) async {
        guard lastSnapshot?.current.sourceText != sourceText else { return }
        await withCheckedContinuation { continuation in
            currentSourceWaiters[sourceText, default: []].append(continuation)
        }
    }

    func waitUntilCurrentTranslation(_ translatedText: String) async {
        guard lastSnapshot?.current.translatedText != translatedText else { return }
        await withCheckedContinuation { continuation in
            currentTranslationWaiters[translatedText, default: []].append(continuation)
        }
    }

    func waitUntilMessage(_ message: String) async {
        guard !messages.contains(message) else { return }
        await withCheckedContinuation { continuation in
            messageWaiters[message, default: []].append(continuation)
        }
    }

    func interpretationSession(
        _ session: InterpretationSession,
        didUpdateState state: TranslationState
    ) {
        states.append(state)
    }

    func interpretationSession(
        _ session: InterpretationSession,
        didUpdateSubtitles snapshot: SubtitleSnapshot
    ) {
        snapshots.append(snapshot)
        let currentWaiters = currentSourceWaiters.removeValue(
            forKey: snapshot.current.sourceText
        ) ?? []
        for waiter in currentWaiters {
            waiter.resume()
        }
        let translationWaiters = currentTranslationWaiters.removeValue(
            forKey: snapshot.current.translatedText
        ) ?? []
        for waiter in translationWaiters {
            waiter.resume()
        }
    }

    func interpretationSession(
        _ session: InterpretationSession,
        didEncounterMessage message: String
    ) {
        messages.append(message)
        let waiters = messageWaiters.removeValue(forKey: message) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
