import XCTest
@testable import RealtimeTranslator

@MainActor
final class InterpretationSessionStaleEchoTests: XCTestCase {
    func testStaleEchoFinalDoesNotClearNewerCurrent() async throws {
        // Given: 文Aの確定訳が未翻訳echoになり、その処理中に文Bがcurrentを占めるセッション
        let speechService = SessionSpeechService()
        let translationService = SessionTranslationService()
        translationService.translations["文A。"] = "文A。"
        translationService.translations["文B。"] = "Sentence B"
        translationService.suspendedFinalTexts.insert("文A。")
        let delegate = SessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            activeTickerIntervalNanoseconds: 60_000_000_000
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "文A", language: .japanese, isFinal: true)
        await translationService.waitUntilFinalRequested("文A。")

        // When: 次の確定文Bがcurrentを占めたあと、文Aのecho結果が返る
        speechService.emit(text: "文B", language: .japanese, isFinal: true)
        await delegate.waitUntilCurrentSource("文B")
        translationService.completeFinal("文A。")
        await translationService.waitUntilFinalRequested("文B。")

        // Then: 遅延echoで文Bを消さず、文Bの確定翻訳へ進む
        XCTAssertEqual(delegate.lastSnapshot?.current.sourceText, "文B")
        XCTAssertFalse(delegate.lastSnapshot?.current.isEmpty == true)
        XCTAssertEqual(translationService.finalRequests, ["文A。", "文B。"])
        await session.stop()
    }

    func testFinalTranslationsProcessInArrivalOrder() async throws {
        // Given: 連続する2件の確定文を順に翻訳するセッション
        let speechService = SessionSpeechService()
        let translationService = SessionTranslationService()
        translationService.translations["一文目。"] = "First"
        translationService.translations["二文目。"] = "Second"
        translationService.suspendedFinalTexts.insert("一文目。")
        translationService.suspendedFinalTexts.insert("二文目。")
        let delegate = SessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            activeTickerIntervalNanoseconds: 60_000_000_000
        )
        session.delegate = delegate
        await session.start()

        // When: 一文目の翻訳完了前に二文目を確定する
        speechService.emit(text: "一文目", language: .japanese, isFinal: true)
        await translationService.waitUntilFinalRequested("一文目。")
        speechService.emit(text: "二文目", language: .japanese, isFinal: true)
        await delegate.waitUntilCurrentSource("二文目")

        // Then: 後続を先に翻訳せず、到着順でキューを処理する
        XCTAssertEqual(translationService.finalRequests, ["一文目。"])
        translationService.completeFinal("一文目。")
        await translationService.waitUntilFinalRequested("二文目。")
        XCTAssertEqual(translationService.finalRequests, ["一文目。", "二文目。"])
        translationService.completeFinal("二文目。")
        await delegate.waitUntilCurrentTranslation("Second")
        XCTAssertEqual(delegate.lastSnapshot?.current.sourceText, "二文目")
        await session.stop()
    }

    func testStartWhileConnectingIsIgnored() async {
        // Given: モデル準備中でconnectingのセッション
        let speechService = SessionSpeechService()
        speechService.suspendsStart = true
        let translationService = SessionTranslationService()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        let startTask = Task { await session.start() }
        await speechService.waitUntilStartCalled()

        // When: connecting中にもう一度開始する
        await session.start()

        // Then: 二重起動せず、最初の開始処理だけが音声サービスを使う
        XCTAssertEqual(session.state, .connecting)
        XCTAssertEqual(speechService.startCallCount, 1)
        await session.stop()
        await startTask.value
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(speechService.startCallCount, 1)
        XCTAssertEqual(speechService.stopCallCount, 1)
    }
}

@MainActor
private final class SessionSpeechService: LocalSpeechRecognitionServicing {
    weak var delegate: LocalSpeechRecognitionServiceDelegate?

    var suspendsStart = false
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

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
        stopCallCount += 1
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

    func waitUntilStartCalled() async {
        guard startCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

@MainActor
private final class SessionTranslationService: LocalTranslationServicing {
    var translations: [String: String] = [:]
    var suspendedFinalTexts: Set<String> = []
    private(set) var finalRequests: [String] = []
    private var finalContinuations: [String: CheckedContinuation<String, Error>] = [:]
    private var finalRequestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        switch priority {
        case .live:
            return translations[text] ?? "Translated: \(text)"
        case .final:
            finalRequests.append(text)
            let waiters = finalRequestWaiters.removeValue(forKey: text) ?? []
            for waiter in waiters {
                waiter.resume()
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
private final class SessionDelegateSpy: InterpretationSessionDelegate {
    private(set) var snapshots: [SubtitleSnapshot] = []
    private var currentSourceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var currentTranslationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

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

    func interpretationSession(
        _ session: InterpretationSession,
        didUpdateState state: TranslationState
    ) {}

    func interpretationSession(
        _ session: InterpretationSession,
        didUpdateSubtitles snapshot: SubtitleSnapshot
    ) {
        snapshots.append(snapshot)
        let sourceWaiters = currentSourceWaiters.removeValue(
            forKey: snapshot.current.sourceText
        ) ?? []
        for waiter in sourceWaiters {
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
    ) {}
}
