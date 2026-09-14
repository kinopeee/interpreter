import XCTest
@testable import RealtimeTranslator

@MainActor
final class InterpretationSessionErrorGuardTests: XCTestCase {
    func testUnknownLanguageDoesNotRetractExistingUtterance() async throws {
        // Given: 日本語の暫定字幕を表示中のセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "表示中の文", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentSource("表示中の文")
        let snapshotCountBeforeUnknown = delegate.snapshots.count

        // When: 表示中に言語不明の暫定結果と確定結果が届く
        speechService.emit(text: "Acme", language: .unknown, isFinal: false)
        speechService.emit(text: "12345", language: .unknown, isFinal: true)

        // Then: 現在の日本語字幕を撤回せず、不明言語を翻訳キューへ入れない
        XCTAssertEqual(delegate.snapshots.count, snapshotCountBeforeUnknown)
        let current = try XCTUnwrap(delegate.lastSnapshot?.current)
        XCTAssertEqual(current.sourceText, "表示中の文")
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "Acme" }
        )
        XCTAssertFalse(translationService.liveRequests.contains("Acme"))
        XCTAssertFalse(translationService.liveRequests.contains("12345"))
        XCTAssertTrue(translationService.finalRequests.isEmpty)
        await session.stop()
    }

    func testOppositeLaneEmptyCancelsUnrenderedPendingWithoutRetractingCurrent() async throws {
        // Given: 日本語原文を描画済みのセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "表示中の文", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentSource("表示中の文")
        let snapshotCountBeforeOpposite = delegate.snapshots.count

        // When: 描画待ちの英語volatileの直後に、同じ英語レーンの空結果が届く
        speechService.emit(text: "hello there", language: .english, isFinal: false)
        speechService.emit(text: "", language: .english, isFinal: false)

        // Then: 未描画の英語をフラッシュせず、日本語currentも撤回しない
        XCTAssertEqual(delegate.snapshots.count, snapshotCountBeforeOpposite)
        let current = try XCTUnwrap(delegate.lastSnapshot?.current)
        XCTAssertEqual(current.sourceText, "表示中の文")
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "hello there" }
        )
        XCTAssertFalse(translationService.liveRequests.contains("hello there"))
        await session.stop()
    }

    func testErrorStateIgnoresLateTranscriptionAfterFailure() async throws {
        // Given: 確定字幕を表示したあと音声障害でerrorへ入ったセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["障害前の文。"] = "Sentence before failure"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "障害前の文", language: .japanese, isFinal: true)
        await delegate.waitUntilCurrentTranslation("Sentence before failure")
        speechService.emitFailure(LocalSpeechRecognitionError.audioFormatUnavailable)
        await delegate.waitUntilMessage("音声認識用の音声形式を取得できません")

        // When: error状態のまま遅延の確定認識が届く
        speechService.emit(text: "障害後の文", language: .japanese, isFinal: true)

        // Then: 障害後の原文で最後の確定字幕を上書きせず、追加の確定訳も依頼しない
        XCTAssertEqual(session.state, .error)
        XCTAssertEqual(delegate.lastSnapshot?.current.sourceText, "障害前の文")
        XCTAssertEqual(delegate.lastSnapshot?.current.translatedText, "Sentence before failure")
        XCTAssertFalse(
            delegate.snapshots.contains { $0.current.sourceText == "障害後の文" }
        )
        XCTAssertEqual(translationService.finalRequests, ["障害前の文。"])
    }
}

@MainActor
private final class FakeSpeechRecognitionService: LocalSpeechRecognitionServicing {
    weak var delegate: LocalSpeechRecognitionServiceDelegate?

    func start() async throws {}

    func stop() async {}

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
