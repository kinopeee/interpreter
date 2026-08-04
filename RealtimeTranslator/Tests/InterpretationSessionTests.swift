import XCTest
@testable import RealtimeTranslator

@MainActor
final class InterpretationSessionTests: XCTestCase {
    func testStopWhileStartingInvalidatesPendingStart() async {
        // Given: 音声認識の開始処理がモデル準備中で停止しているセッション
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

        // When: 開始完了前に録音を停止する
        await session.stop()
        await startTask.value

        // Then: 古い開始処理は失効し、listeningへ遷移しない
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(delegate.states.contains(.listening))
        XCTAssertEqual(speechService.stopCallCount, 1)
    }

    func testRepeatedStopWhileClosingDoesNotRepeatTeardown() async {
        // Given: 録音中で、最初の停止処理が完了待ちのセッション
        let speechService = FakeSpeechRecognitionService()
        speechService.suspendsStop = true
        let translationService = FakeTranslationService()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        await session.start()
        let firstStopTask = Task { await session.stop() }
        await speechService.waitUntilStopCalled()

        // When: closing中にもう一度停止する
        let secondStopCompletion = CompletionProbe()
        let secondStopTask = Task { @MainActor in
            secondStopCompletion.markStarted()
            await session.stop()
            secondStopCompletion.isComplete = true
        }
        await secondStopCompletion.waitUntilStarted()

        // Then: 音声サービスのteardownは1回だけ実行し、両方の要求が同じ停止を待つ
        XCTAssertEqual(session.state, .closing)
        XCTAssertEqual(speechService.stopCallCount, 1)
        XCTAssertFalse(secondStopCompletion.isComplete)
        speechService.resumeStop()
        await firstStopTask.value
        await secondStopTask.value
        XCTAssertTrue(secondStopCompletion.isComplete)
        XCTAssertEqual(session.state, .idle)
    }

    func testFinalTranslationSurvivesNextLiveTranscription() async throws {
        // Given: 確定文Aの翻訳が処理中のセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.suspendedFinalTexts.insert("文A")
        translationService.translations["文A"] = "Sentence A"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "文A", language: .japanese, isFinal: true)
        await translationService.waitUntilFinalRequested("文A")

        // When: 翻訳完了前に次の暫定文Bが届く
        speechService.emit(text: "文B", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentSource("文B")
        translationService.completeFinal("文A")
        await delegate.waitUntilPreviousSource("文A")

        // Then: 文Aを確定表示し、文Bをcurrentとして維持する
        let snapshot = try XCTUnwrap(delegate.lastSnapshot)
        XCTAssertEqual(snapshot.previous?.sourceText, "文A")
        XCTAssertEqual(snapshot.previous?.translatedText, "Sentence A")
        XCTAssertEqual(snapshot.current.sourceText, "文B")
        XCTAssertEqual(translationService.finalRequests, ["文A"])
        await session.stop()
    }

    func testStopDrainsFinalRecognitionAndTranslation() async throws {
        // Given: 停止時にSpeechAnalyzerの最終結果を返す録音セッション
        let speechService = FakeSpeechRecognitionService()
        speechService.finalResultOnStop = (
            text: "最後の文",
            language: .japanese
        )
        let translationService = FakeTranslationService()
        translationService.suspendedFinalTexts.insert("最後の文")
        translationService.translations["最後の文"] = "The final sentence"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()

        // When: 録音を停止してfinal認識と翻訳をドレインする
        let stopTask = Task { await session.stop() }
        await translationService.waitUntilFinalRequested("最後の文")
        XCTAssertEqual(session.state, .closing)
        translationService.completeFinal("最後の文")
        await stopTask.value

        // Then: finalの原文・訳文ペアを確定してからidleへ遷移する
        let snapshot = try XCTUnwrap(delegate.lastSnapshot)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(snapshot.previous?.sourceText, "最後の文")
        XCTAssertEqual(snapshot.previous?.translatedText, "The final sentence")
        XCTAssertTrue(snapshot.current.isEmpty)
        XCTAssertEqual(translationService.finalRequests, ["最後の文"])
    }

    func testCancellationErrorDoesNotAbandonFollowingFinalTranslation() async {
        // Given: 確定文AだけがCancellationErrorとなる翻訳キュー
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.cancelledFinalTexts.insert("文A")
        translationService.translations["文B"] = "Sentence B"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()

        // When: 文Aと文Bを連続して確定キューへ入れる
        speechService.emit(text: "文A", language: .japanese, isFinal: true)
        speechService.emit(text: "文B", language: .japanese, isFinal: true)
        await delegate.waitUntilPreviousSource("文B")

        // Then: 文Aの取消後も文Bを処理して確定表示する
        XCTAssertEqual(translationService.finalRequests, ["文A", "文B"])
        XCTAssertEqual(delegate.lastSnapshot?.previous?.translatedText, "Sentence B")
        await session.stop()
    }
}

@MainActor
private final class FakeSpeechRecognitionService: LocalSpeechRecognitionServicing {
    weak var delegate: LocalSpeechRecognitionServiceDelegate?

    var suspendsStart = false
    var suspendsStop = false
    var finalResultOnStop: (text: String, language: SpokenLanguage)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

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
        stopCallCount += 1
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if let finalResultOnStop {
            delegate?.localSpeechRecognitionService(
                didUpdate: finalResultOnStop.text,
                language: finalResultOnStop.language,
                isFinal: true
            )
        }
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: CancellationError())
        }
        guard suspendsStop else { return }

        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func emit(text: String, language: SpokenLanguage, isFinal: Bool) {
        delegate?.localSpeechRecognitionService(
            didUpdate: text,
            language: language,
            isFinal: isFinal
        )
    }

    func waitUntilStartCalled() async {
        guard startCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilStopCalled() async {
        guard stopCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func resumeStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class FakeTranslationService: LocalTranslationServicing {
    var translations: [String: String] = [:]
    var suspendedFinalTexts: Set<String> = []
    var cancelledFinalTexts: Set<String> = []
    private(set) var finalRequests: [String] = []
    private(set) var liveRequests: [String] = []
    private var finalContinuations: [String: CheckedContinuation<String, Error>] = [:]
    private var finalRequestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

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
            let waiters = finalRequestWaiters.removeValue(forKey: text) ?? []
            for waiter in waiters {
                waiter.resume()
            }
            if cancelledFinalTexts.contains(text) {
                throw CancellationError()
            }
            if suspendedFinalTexts.contains(text) {
                return try await withCheckedThrowingContinuation { continuation in
                    finalContinuations[text] = continuation
                }
            }
            return translations[text] ?? "Translated: \(text)"
        }
    }

    func waitUntilFinalRequested(_ text: String) async {
        guard !finalRequests.contains(text) else { return }
        await withCheckedContinuation { continuation in
            finalRequestWaiters[text, default: []].append(continuation)
        }
    }

    func completeFinal(_ text: String) {
        let continuation = finalContinuations.removeValue(forKey: text)
        continuation?.resume(returning: translations[text] ?? "Translated: \(text)")
    }
}

@MainActor
private final class InterpretationSessionDelegateSpy: InterpretationSessionDelegate {
    private(set) var states: [TranslationState] = []
    private(set) var snapshots: [SubtitleSnapshot] = []
    private(set) var messages: [String] = []
    private var currentSourceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var previousSourceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    var lastSnapshot: SubtitleSnapshot? {
        snapshots.last
    }

    func waitUntilCurrentSource(_ sourceText: String) async {
        guard lastSnapshot?.current.sourceText != sourceText else { return }
        await withCheckedContinuation { continuation in
            currentSourceWaiters[sourceText, default: []].append(continuation)
        }
    }

    func waitUntilPreviousSource(_ sourceText: String) async {
        guard lastSnapshot?.previous?.sourceText != sourceText else { return }
        await withCheckedContinuation { continuation in
            previousSourceWaiters[sourceText, default: []].append(continuation)
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
        if let previousSource = snapshot.previous?.sourceText {
            let previousWaiters = previousSourceWaiters.removeValue(
                forKey: previousSource
            ) ?? []
            for waiter in previousWaiters {
                waiter.resume()
            }
        }
    }

    func interpretationSession(
        _ session: InterpretationSession,
        didEncounterMessage message: String
    ) {
        messages.append(message)
    }
}

@MainActor
private final class CompletionProbe {
    var isComplete = false
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        isStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}
