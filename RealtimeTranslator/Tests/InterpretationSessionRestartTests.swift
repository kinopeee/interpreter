import XCTest
@testable import RealtimeTranslator

@MainActor
final class InterpretationSessionRestartTests: XCTestCase {
    func testStartAfterIdleStopClearsPreviousSubtitleAndListens() async throws {
        // Given: 確定字幕を残したままidleへ戻ったセッション
        let speechService = FakeRestartSpeechRecognitionService()
        let translationService = FakeRestartTranslationService()
        translationService.translations["完了文。"] = "Completed sentence"
        let delegate = RestartSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "完了文", language: .japanese, isFinal: true)
        await delegate.waitUntilCurrentTranslation("Completed sentence")
        await session.stop()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(delegate.lastSnapshot?.current.translatedText, "Completed sentence")
        XCTAssertEqual(speechService.startCallCount, 1)

        // When: 同じセッションで録音を再開する
        await session.start()

        // Then: 前回の確定字幕をresetし、2回目の認識開始後にlisteningへ戻る
        XCTAssertEqual(speechService.startCallCount, 2)
        XCTAssertEqual(speechService.stopCallCount, 1)
        XCTAssertEqual(session.state, .listening)
        XCTAssertTrue(session.isTickerRunning)
        let snapshot = try XCTUnwrap(delegate.lastSnapshot)
        XCTAssertTrue(snapshot.current.isEmpty)
        XCTAssertEqual(snapshot.statusBanner, "録音中… 話してください")
    }
}

@MainActor
private final class FakeRestartSpeechRecognitionService: LocalSpeechRecognitionServicing {
    weak var delegate: LocalSpeechRecognitionServiceDelegate?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() async throws {
        startCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
    }

    func emit(text: String, language: SpokenLanguage, isFinal: Bool) {
        delegate?.localSpeechRecognitionService(
            didUpdate: text,
            language: language,
            isFinal: isFinal
        )
    }
}

@MainActor
private final class FakeRestartTranslationService: LocalTranslationServicing {
    var translations: [String: String] = [:]

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        translations[text] ?? "Translated: \(text)"
    }
}

@MainActor
private final class RestartSessionDelegateSpy: InterpretationSessionDelegate {
    private(set) var snapshots: [SubtitleSnapshot] = []
    private var currentTranslationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    var lastSnapshot: SubtitleSnapshot? {
        snapshots.last
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
        let waiters = currentTranslationWaiters.removeValue(
            forKey: snapshot.current.translatedText
        ) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func interpretationSession(
        _ session: InterpretationSession,
        didEncounterMessage message: String
    ) {}
}
