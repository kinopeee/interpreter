import XCTest
@testable import RealtimeTranslator

@MainActor
final class InterpretationSessionRecoveryTests: XCTestCase {
    func testEnglishFinalUsesEnglishNormalizerAndLanguage() async throws {
        // Given: 英語確定文を受け付けるセッション
        let speechService = SessionSpeechService()
        let translationService = SessionTranslationService()
        translationService.translations["Hello there."] = "こんにちは"
        let delegate = SessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()

        // When: 句点のない英語文を確定する
        speechService.emit(text: "Hello there", language: .english, isFinal: true)
        await delegate.waitUntilCurrentTranslation("こんにちは")

        // Then: 英日方向の正規化(「.」)と英語レーンを翻訳器へ渡す
        XCTAssertEqual(translationService.finalRequests, ["Hello there."])
        XCTAssertEqual(translationService.finalLanguages, [.english])
        let snapshot = try XCTUnwrap(delegate.lastSnapshot)
        XCTAssertEqual(snapshot.current.sourceText, "Hello there")
        XCTAssertEqual(snapshot.current.translatedText, "こんにちは")
        await session.stop()
    }

    func testLiveTranslationFailureKeepsSourceAndShowsPreparationBanner() async throws {
        // Given: live翻訳が準備失敗するセッション
        let speechService = SessionSpeechService()
        let translationService = SessionTranslationService()
        translationService.failingLiveTexts.insert("文A")
        let delegate = SessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()

        // When: 暫定原文のlive翻訳が失敗する
        speechService.emit(text: "文A", language: .japanese, isFinal: false)
        await delegate.waitUntilStatusBanner("ローカル翻訳を準備中…")

        // Then: 原文は残し、失敗を確定扱いにせず準備中バナーを出す
        let snapshot = try XCTUnwrap(delegate.lastSnapshot)
        XCTAssertEqual(snapshot.current.sourceText, "文A")
        XCTAssertTrue(snapshot.current.translatedText.isEmpty)
        XCTAssertFalse(snapshot.current.isTranslationCurrent)
        XCTAssertEqual(snapshot.statusBanner, "ローカル翻訳を準備中…")
        XCTAssertEqual(translationService.liveRequests, ["文A"])
        await session.stop()
    }

    func testIdenticalVolatileUpdateDoesNotRepublishCurrent() async {
        // Given: 同じ暫定原文をすでに表示しているセッション
        let speechService = SessionSpeechService()
        let translationService = SessionTranslationService()
        translationService.translations["文A"] = "Sentence A"
        let delegate = SessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            activeTickerIntervalNanoseconds: 60_000_000_000
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "文A", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentTranslation("Sentence A")
        let snapshotCount = delegate.snapshots.count

        // When: 内容が変わらないvolatile結果が再送される
        speechService.emit(text: "文A", language: .japanese, isFinal: false)

        // Then: 同一原文の再描画も追加の翻訳依頼もしない
        XCTAssertEqual(delegate.snapshots.count, snapshotCount)
        XCTAssertEqual(translationService.liveRequests, ["文A"])
        await session.stop()
    }

    func testStopWhileIdleDoesNotTouchSpeechService() async {
        // Given: まだ録音を開始していないセッション
        let speechService = SessionSpeechService()
        let translationService = SessionTranslationService()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )

        // When: idleのまま停止する
        await session.stop()

        // Then: 音声経路のteardownを走らせずidleを維持する
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(speechService.startCallCount, 0)
        XCTAssertEqual(speechService.stopCallCount, 0)
    }
}

@MainActor
private final class SessionSpeechService: LocalSpeechRecognitionServicing {
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
private final class SessionTranslationService: LocalTranslationServicing {
    var translations: [String: String] = [:]
    var failingLiveTexts: Set<String> = []
    private(set) var liveRequests: [String] = []
    private(set) var finalRequests: [String] = []
    private(set) var finalLanguages: [SpokenLanguage] = []

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        switch priority {
        case .live:
            liveRequests.append(text)
            if failingLiveTexts.contains(text) {
                throw LocalTranslationError.sessionUnavailable
            }
            return translations[text] ?? "Translated: \(text)"
        case .final:
            finalRequests.append(text)
            finalLanguages.append(language)
            return translations[text] ?? "Translated: \(text)"
        }
    }
}

@MainActor
private final class SessionDelegateSpy: InterpretationSessionDelegate {
    private(set) var snapshots: [SubtitleSnapshot] = []
    private var currentTranslationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var bannerWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    var lastSnapshot: SubtitleSnapshot? {
        snapshots.last
    }

    func waitUntilCurrentTranslation(_ translatedText: String) async {
        guard lastSnapshot?.current.translatedText != translatedText else { return }
        await withCheckedContinuation { continuation in
            currentTranslationWaiters[translatedText, default: []].append(continuation)
        }
    }

    func waitUntilStatusBanner(_ banner: String) async {
        guard lastSnapshot?.statusBanner != banner else { return }
        await withCheckedContinuation { continuation in
            bannerWaiters[banner, default: []].append(continuation)
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
        let translationWaiters = currentTranslationWaiters.removeValue(
            forKey: snapshot.current.translatedText
        ) ?? []
        for waiter in translationWaiters {
            waiter.resume()
        }
        if let banner = snapshot.statusBanner {
            let waiters = bannerWaiters.removeValue(forKey: banner) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func interpretationSession(
        _ session: InterpretationSession,
        didEncounterMessage message: String
    ) {}
}
