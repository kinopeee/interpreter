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

    func testTransientFinalTranslationFailureRetriesAndFinalizes() async throws {
        // Given: 確定翻訳が2回だけ準備失敗し、3回目で成功するセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["文A"] = "Sentence A"
        translationService.finalFailureCounts["文A"] = 2
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            maxFinalTranslationAttempts: 5,
            finalTranslationRetryDelayNanoseconds: 0
        )
        session.delegate = delegate
        await session.start()

        // When: 確定文Aを1件だけキューへ入れる
        speechService.emit(text: "文A", language: .japanese, isFinal: true)
        await delegate.waitUntilPreviousSource("文A")

        // Then: 一時失敗後も同じ確定文を再試行し、原文・訳文ペアを失わない
        XCTAssertEqual(translationService.finalRequests, ["文A", "文A", "文A"])
        let snapshot = try XCTUnwrap(delegate.lastSnapshot)
        XCTAssertEqual(snapshot.previous?.sourceText, "文A")
        XCTAssertEqual(snapshot.previous?.translatedText, "Sentence A")
        XCTAssertTrue(snapshot.current.isEmpty)
        await session.stop()
    }

    func testFinalTranslationFailureEventuallyGivesUpWithoutBlockingNext() async throws {
        // Given: 文Aの確定翻訳が常に失敗し、文Bは成功するセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["文B"] = "Sentence B"
        translationService.finalFailureCounts["文A"] = 100
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            maxFinalTranslationAttempts: 2,
            finalTranslationRetryDelayNanoseconds: 0
        )
        session.delegate = delegate
        await session.start()

        // When: 失敗し続ける文Aのあとに文Bを確定する
        speechService.emit(text: "文A", language: .japanese, isFinal: true)
        speechService.emit(text: "文B", language: .japanese, isFinal: true)
        await delegate.waitUntilPreviousSource("文B")

        // Then: 文Aは再試行上限で打ち切り、文Bの確定を阻害しない
        XCTAssertEqual(translationService.finalRequests, ["文A", "文A", "文B"])
        let snapshot = try XCTUnwrap(delegate.lastSnapshot)
        XCTAssertEqual(snapshot.previous?.sourceText, "文B")
        XCTAssertEqual(snapshot.previous?.translatedText, "Sentence B")
        await session.stop()
    }

    func testEmptyRecognitionRetractsCurrentWithoutTranslation() async {
        // Given: 日本語の暫定字幕を表示し、翻訳debounce中のセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "暫定字幕", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentSource("暫定字幕")

        // When: 同じ認識レーンから空のvolatile結果が届く
        speechService.emit(text: "", language: .japanese, isFinal: false)

        // Then: currentを撤回し、空文字を翻訳要求へ送らない
        XCTAssertTrue(delegate.lastSnapshot?.current.isEmpty == true)
        XCTAssertTrue(translationService.liveRequests.isEmpty)
        XCTAssertTrue(translationService.finalRequests.isEmpty)
        await session.stop()
    }

    func testEmptyFinalDoesNotBlockFollowingFinalSentence() async {
        // Given: 日本語の暫定字幕を表示しているセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["次の文"] = "The next sentence"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "撤回対象", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentSource("撤回対象")

        // When: 空finalで撤回した後、次の確定文が届く
        speechService.emit(text: "", language: .japanese, isFinal: true)
        speechService.emit(text: "次の文", language: .japanese, isFinal: true)
        await delegate.waitUntilPreviousSource("次の文")

        // Then: 空文字をキューへ入れず、次の文だけを翻訳する
        XCTAssertEqual(translationService.finalRequests, ["次の文"])
        XCTAssertEqual(
            delegate.lastSnapshot?.previous?.translatedText,
            "The next sentence"
        )
        await session.stop()
    }

    func testSameLanguageUpdateKeepsPreviousTranslationAsStale() async throws {
        // Given: 日本語の暫定原文と対応するlive訳文を表示中のセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["最初の認識"] = "Initial recognition"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(
            text: "最初の認識",
            language: .japanese,
            isFinal: false
        )
        await delegate.waitUntilCurrentTranslation("Initial recognition")

        // When: 同じ認識レーンの原文が続きまで更新される
        speechService.emit(
            text: "最初の認識の続き",
            language: .japanese,
            isFinal: false
        )
        await delegate.waitUntilCurrentSource("最初の認識の続き")

        // Then: 旧訳文を参考表示しつつ、現在訳や確定可能とは扱わない
        let current = try XCTUnwrap(delegate.lastSnapshot?.current)
        XCTAssertEqual(current.sourceText, "最初の認識の続き")
        XCTAssertEqual(current.translatedText, "Initial recognition")
        XCTAssertFalse(current.isTranslationCurrent)
        XCTAssertFalse(current.canFinalize)
        await session.stop()
    }

    func testLanguageChangeClearsPreviousTranslation() async throws {
        // Given: 日本語原文のlive訳文を表示中のセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["日本語です"] = "This is Japanese"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "日本語です", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentTranslation("This is Japanese")

        // When: 英語レーンの新しい原文へ切り替わる
        speechService.emit(text: "Now English", language: .english, isFinal: false)
        await delegate.waitUntilCurrentSource("Now English")

        // Then: 異なる言語の旧訳文を新しい原文へ引き継がない
        let current = try XCTUnwrap(delegate.lastSnapshot?.current)
        XCTAssertEqual(current.sourceText, "Now English")
        XCTAssertTrue(current.translatedText.isEmpty)
        XCTAssertFalse(current.isTranslationCurrent)
        XCTAssertFalse(current.canFinalize)
        await session.stop()
    }

    func testStaleLiveTranslationDoesNotOverwriteNewerUtterance() async throws {
        // Given: 文Aのlive翻訳を完了待ちにしているセッション
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["文A"] = "Sentence A"
        translationService.translations["文B"] = "Sentence B"
        translationService.suspendedLiveTexts.insert("文A")
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "文A", language: .japanese, isFinal: false)
        await translationService.waitUntilLiveRequested("文A")

        // When: 原文を文Bへ更新した後で、古い文Aの翻訳を完了する
        speechService.emit(text: "文B", language: .japanese, isFinal: false)
        await delegate.waitUntilCurrentSource("文B")
        translationService.completeLive("文A")
        await delegate.waitUntilCurrentTranslation("Sentence B")

        // Then: 文Bの表示履歴へ文Aの古い訳文を一度も反映しない
        let current = try XCTUnwrap(delegate.lastSnapshot?.current)
        XCTAssertEqual(current.sourceText, "文B")
        XCTAssertEqual(current.translatedText, "Sentence B")
        XCTAssertFalse(
            delegate.snapshots.contains {
                $0.current.sourceText == "文B"
                    && $0.current.translatedText == "Sentence A"
            }
        )
        await session.stop()
    }

    func testFinalTranslationQueueRejectsNewestBeyondCapacity() async {
        // Given: 実行中の文Aと、1件だけ待機可能な確定翻訳キュー
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.suspendedFinalTexts.insert("文A")
        translationService.translations["文A"] = "Sentence A"
        translationService.translations["文B"] = "Sentence B"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            maxPendingFinalTranslations: 1
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "文A", language: .japanese, isFinal: true)
        await translationService.waitUntilFinalRequested("文A")

        // When: 待機文Bと上限超過の文Cを続けて投入する
        speechService.emit(text: "文B", language: .japanese, isFinal: true)
        speechService.emit(text: "文C", language: .japanese, isFinal: true)
        translationService.completeFinal("文A")
        await translationService.waitUntilFinalRequested("文B")
        await delegate.waitUntilPreviousSource("文B")

        // Then: 文Cを保持せず、上限メッセージとA・Bだけを処理する
        XCTAssertEqual(translationService.finalRequests, ["文A", "文B"])
        XCTAssertTrue(
            delegate.snapshots.contains {
                $0.statusBanner == "確定翻訳の待機件数が上限に達しました"
            }
        )
        await session.stop()
    }

    func testFinalSubtitleExpiresAfterStop() async {
        // Given: 停止後の保持・fade時間を即時化した字幕集約器
        var config = SubtitleAggregatorConfig()
        config.previousHoldInterval = 0.01
        config.fadeDuration = 0
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["完了文"] = "Completed sentence"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            aggregator: SubtitleAggregator(config: config),
            activeTickerIntervalNanoseconds: 10_000_000_000,
            idleTickerIntervalNanoseconds: 1_000_000
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(text: "完了文", language: .japanese, isFinal: true)
        await delegate.waitUntilPreviousSource("完了文")

        // When: 録音を停止し、idle中の消去tickを待つ
        await session.stop()
        await delegate.waitUntilFinalizedSubtitleClears()

        // Then: 最終字幕を無期限保持せず、空のsnapshotへ遷移する
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(delegate.lastSnapshot?.current.isEmpty == true)
        XCTAssertNil(delegate.lastSnapshot?.previous)
    }

    func testSpeechFailureNotifiesOnlyAfterStopCompletes() async {
        // Given: 音声停止を明示再開まで保留する録音セッション
        let speechService = FakeSpeechRecognitionService()
        speechService.suspendsStop = true
        let translationService = FakeTranslationService()
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService
        )
        session.delegate = delegate
        await session.start()

        // When: 音声エラーを通知し、停止処理が待機状態へ入る
        speechService.emitFailure(LocalSpeechRecognitionError.audioFormatUnavailable)
        await speechService.waitUntilStopCalled()

        // Then: 停止中はユーザー通知を出さず、停止後に型付きメッセージを1回だけ出す
        XCTAssertEqual(session.state, .closing)
        XCTAssertTrue(delegate.messages.isEmpty)
        speechService.resumeStop()
        await delegate.waitUntilMessage(
            "音声認識用の音声形式を取得できません"
        )
        XCTAssertEqual(session.state, .error)
        XCTAssertEqual(
            Array(delegate.states.suffix(3)),
            [.closing, .idle, .error]
        )
        XCTAssertEqual(
            delegate.messages,
            ["音声認識用の音声形式を取得できません"]
        )
    }

    func testSpeechFailureStopsTickerAfterFinalSubtitleClears() async {
        // Given: 確定字幕を表示中で、停止後だけ短い間隔で消去するセッション
        var config = SubtitleAggregatorConfig()
        config.previousHoldInterval = 0.01
        config.fadeDuration = 0
        let speechService = FakeSpeechRecognitionService()
        let translationService = FakeTranslationService()
        translationService.translations["障害前の文"] = "Sentence before failure"
        let delegate = InterpretationSessionDelegateSpy()
        let session = InterpretationSession(
            translationService: translationService,
            speechService: speechService,
            aggregator: SubtitleAggregator(config: config),
            activeTickerIntervalNanoseconds: 10_000_000_000,
            idleTickerIntervalNanoseconds: 1_000_000
        )
        session.delegate = delegate
        await session.start()
        speechService.emit(
            text: "障害前の文",
            language: .japanese,
            isFinal: true
        )
        await delegate.waitUntilPreviousSource("障害前の文")

        // When: 音声障害でstop後にerrorへ遷移し、字幕が消える
        speechService.emitFailure(LocalSpeechRecognitionError.audioFormatUnavailable)
        await delegate.waitUntilMessage(
            "音声認識用の音声形式を取得できません"
        )
        await delegate.waitUntilFinalizedSubtitleClears()

        // Then: error状態でもidle用tickerを保持し続けない
        XCTAssertEqual(session.state, .error)
        XCTAssertFalse(session.isTickerRunning)
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

    func emitFailure(_ error: Error) {
        delegate?.localSpeechRecognitionService(didFail: error)
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
    var suspendedLiveTexts: Set<String> = []
    var suspendedFinalTexts: Set<String> = []
    var cancelledFinalTexts: Set<String> = []
    var finalFailureCounts: [String: Int] = [:]
    private(set) var finalRequests: [String] = []
    private(set) var liveRequests: [String] = []
    private var liveContinuations: [String: CheckedContinuation<String, Error>] = [:]
    private var finalContinuations: [String: CheckedContinuation<String, Error>] = [:]
    private var liveRequestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finalRequestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func translate(
        _ text: String,
        from language: SpokenLanguage,
        priority: LocalTranslationPriority
    ) async throws -> String {
        switch priority {
        case .live:
            liveRequests.append(text)
            let waiters = liveRequestWaiters.removeValue(forKey: text) ?? []
            for waiter in waiters {
                waiter.resume()
            }
            if suspendedLiveTexts.contains(text) {
                return try await withCheckedThrowingContinuation { continuation in
                    liveContinuations[text] = continuation
                }
            }
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
            if let remainingFailures = finalFailureCounts[text], remainingFailures > 0 {
                finalFailureCounts[text] = remainingFailures - 1
                throw LocalTranslationError.sessionUnavailable
            }
            if suspendedFinalTexts.contains(text) {
                return try await withCheckedThrowingContinuation { continuation in
                    finalContinuations[text] = continuation
                }
            }
            return translations[text] ?? "Translated: \(text)"
        }
    }

    func waitUntilLiveRequested(_ text: String) async {
        guard !liveRequests.contains(text) else { return }
        await withCheckedContinuation { continuation in
            liveRequestWaiters[text, default: []].append(continuation)
        }
    }

    func completeLive(_ text: String) {
        let continuation = liveContinuations.removeValue(forKey: text)
        continuation?.resume(returning: translations[text] ?? "Translated: \(text)")
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
    private var currentTranslationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var previousSourceWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var messageWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finalizedSubtitleClearWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasSeenFinalizedSubtitle = false

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

    func waitUntilPreviousSource(_ sourceText: String) async {
        guard lastSnapshot?.previous?.sourceText != sourceText else { return }
        await withCheckedContinuation { continuation in
            previousSourceWaiters[sourceText, default: []].append(continuation)
        }
    }

    func waitUntilMessage(_ message: String) async {
        guard !messages.contains(message) else { return }
        await withCheckedContinuation { continuation in
            messageWaiters[message, default: []].append(continuation)
        }
    }

    func waitUntilFinalizedSubtitleClears() async {
        if hasSeenFinalizedSubtitle,
           lastSnapshot?.current.isEmpty == true,
           lastSnapshot?.previous == nil
        {
            return
        }
        await withCheckedContinuation { continuation in
            finalizedSubtitleClearWaiters.append(continuation)
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
        if snapshot.previous != nil {
            hasSeenFinalizedSubtitle = true
        }
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
        if let previousSource = snapshot.previous?.sourceText {
            let previousWaiters = previousSourceWaiters.removeValue(
                forKey: previousSource
            ) ?? []
            for waiter in previousWaiters {
                waiter.resume()
            }
        }
        if hasSeenFinalizedSubtitle,
           snapshot.current.isEmpty,
           snapshot.previous == nil
        {
            let clearWaiters = finalizedSubtitleClearWaiters
            finalizedSubtitleClearWaiters.removeAll()
            for waiter in clearWaiters {
                waiter.resume()
            }
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
