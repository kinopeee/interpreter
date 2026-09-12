import XCTest
@testable import RealtimeTranslator

@MainActor
final class InterpretationSessionStartCancellationTests: XCTestCase {
    func testStartCancellationReturnsToIdleWithoutTeardown() async {
        // Given: 音声認識の開始がCancellationErrorを返すセッション
        let speechService = CancellingSpeechRecognitionService()
        let translationService = ImmediateTranslationService()
        let delegate = StateOnlySessionDelegate()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate

        // When: 録音開始を要求する
        await session.start()

        // Then: 内部キャンセルはerrorにせずidleへ戻し、stop経路は走らない
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(speechService.startCallCount, 1)
        XCTAssertEqual(speechService.stopCallCount, 0)
        XCTAssertEqual(delegate.states, [.connecting, .idle])
        XCTAssertFalse(delegate.states.contains(.error))
        XCTAssertFalse(delegate.states.contains(.listening))
        XCTAssertTrue(delegate.messages.isEmpty)
    }
}

@MainActor
private final class CancellingSpeechRecognitionService: LocalSpeechRecognitionServicing {
    weak var delegate: LocalSpeechRecognitionServiceDelegate?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() async throws {
        startCallCount += 1
        throw CancellationError()
    }

    func stop() async {
        stopCallCount += 1
    }
}

@MainActor
private final class ImmediateTranslationService: LocalTranslationServicing {
    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        "Translated: \(text)"
    }
}

@MainActor
private final class StateOnlySessionDelegate: InterpretationSessionDelegate {
    private(set) var states: [TranslationState] = []
    private(set) var messages: [String] = []

    func interpretationSession(
        _: InterpretationSession,
        didUpdateState state: TranslationState
    ) {
        states.append(state)
    }

    func interpretationSession(
        _: InterpretationSession,
        didUpdateSubtitles _: SubtitleSnapshot
    ) {}

    func interpretationSession(
        _: InterpretationSession,
        didEncounterMessage message: String
    ) {
        messages.append(message)
    }
}
