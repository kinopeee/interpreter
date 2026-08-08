import Foundation

@MainActor
protocol InterpretationSessionDelegate: AnyObject {
    func interpretationSession(
        _ session: InterpretationSession,
        didUpdateState state: TranslationState
    )
    func interpretationSession(
        _ session: InterpretationSession,
        didUpdateSubtitles snapshot: SubtitleSnapshot
    )
    func interpretationSession(
        _ session: InterpretationSession,
        didEncounterMessage message: String
    )
}

@MainActor
final class InterpretationSession {
    /// 発話途中の原文表示の最小間隔。AGENTS.mdの字幕UI不変条件
    /// 「発話途中の原文表示は約160ms間隔に抑え、行高を維持してちらつきを防ぐ」に対応する。
    private static let transcriptionRenderInterval: TimeInterval = 0.16
    /// 発話途中のlive翻訳を依頼するまでのデバウンス。原文が細かく更新される間は
    /// 翻訳を待ち、無駄な翻訳依頼と訳文のちらつきを抑える。
    private static let liveTranslationDebounceNanoseconds: UInt64 = 300_000_000

    private struct PendingTranscription {
        let text: String
        let language: SpokenLanguage
        let isFinal: Bool
    }

    private struct CurrentUtterance {
        /// 原文更新のたびに増える世代番号。翻訳結果の適用時に照合し、
        /// 発話更新前の古い訳文が画面へ反映されるのを防ぐ(AGENTS.mdの不変条件)。
        private(set) var generation = 0
        private(set) var sourceText = ""
        private(set) var translatedText = ""
        private(set) var language: SpokenLanguage = .unknown

        mutating func reset() {
            self = CurrentUtterance()
        }

        @discardableResult
        mutating func updateSource(
            _ sourceText: String,
            language: SpokenLanguage
        ) -> Int {
            generation += 1
            let preservesTranslation = language == self.language
                && !translatedText.isEmpty
                && !self.sourceText.isEmpty
            if !preservesTranslation {
                translatedText = ""
            }
            self.sourceText = sourceText
            self.language = language
            return generation
        }

        mutating func retract() {
            generation += 1
            clearContent()
        }

        mutating func clearContent() {
            sourceText = ""
            translatedText = ""
            language = .unknown
        }

        mutating func applyTranslation(
            _ translatedText: String,
            generation: Int,
            sourceText: String
        ) -> Bool {
            guard generation == self.generation,
                  sourceText == self.sourceText
            else {
                return false
            }
            self.translatedText = translatedText
            return true
        }
    }

    private struct FinalTranslationRequest {
        let sourceText: String
        let language: SpokenLanguage
        let sourceGeneration: Int
        var attemptCount: Int
    }

    weak var delegate: InterpretationSessionDelegate?

    private let speechService: any LocalSpeechRecognitionServicing
    private let translationService: any LocalTranslationServicing
    private let aggregator: SubtitleAggregator
    private let maxPendingFinalTranslations: Int
    private let maxFinalTranslationAttempts: Int
    private let finalTranslationRetryDelayNanoseconds: UInt64
    private let activeTickerIntervalNanoseconds: UInt64
    /// live訳文を一度表示したら次の書き換えまで最低これだけ保持する。
    /// 読んでいる最中に訳文全体が語順ごと書き換わるちらつきを抑える。
    /// 確定訳(final)の表示には適用しない。
    private let liveTranslationDisplayHoldInterval: TimeInterval

    private(set) var state: TranslationState = .idle {
        didSet {
            guard oldValue != state else { return }
            delegate?.interpretationSession(self, didUpdateState: state)
        }
    }

    var isTickerRunning: Bool {
        tickerTask != nil
    }

    private var tickerTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var liveTranslationTask: Task<Void, Never>?
    private var finalTranslationWorker: Task<Void, Never>?
    private var finalTranslationQueue: [FinalTranslationRequest] = []
    private var transcriptionRenderTask: Task<Void, Never>?
    private var pendingTranscription: PendingTranscription?
    private var lastTranscriptionRenderedAt = Date.distantPast
    private var lastLiveTranslationDisplayedAt = Date.distantPast
    /// start/stopの世代番号。起動待ちの間に停止が割り込んだ場合、
    /// 古い起動処理が状態を上書きするのを防ぐ。
    private var lifecycleGeneration = 0
    private var currentUtterance = CurrentUtterance()

    init(
        translationService: any LocalTranslationServicing,
        speechService: any LocalSpeechRecognitionServicing = LocalSpeechRecognitionService(),
        aggregator: SubtitleAggregator = SubtitleAggregator(),
        maxPendingFinalTranslations: Int = 32,
        maxFinalTranslationAttempts: Int = 5,
        finalTranslationRetryDelayNanoseconds: UInt64 = 250_000_000,
        activeTickerIntervalNanoseconds: UInt64 = 200_000_000,
        liveTranslationDisplayHoldNanoseconds: UInt64 = 1_500_000_000
    ) {
        precondition(maxPendingFinalTranslations > 0)
        precondition(maxFinalTranslationAttempts > 0)
        self.translationService = translationService
        self.speechService = speechService
        self.aggregator = aggregator
        self.maxPendingFinalTranslations = maxPendingFinalTranslations
        self.maxFinalTranslationAttempts = maxFinalTranslationAttempts
        self.finalTranslationRetryDelayNanoseconds = finalTranslationRetryDelayNanoseconds
        self.activeTickerIntervalNanoseconds = activeTickerIntervalNanoseconds
        self.liveTranslationDisplayHoldInterval =
            TimeInterval(liveTranslationDisplayHoldNanoseconds) / 1_000_000_000
        speechService.delegate = self
    }

    func start() async {
        guard state == .idle || state == .error else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        state = .connecting
        aggregator.reset()
        cancelTransientWork()
        currentUtterance.reset()
        finalTranslationQueue.removeAll()
        lastLiveTranslationDisplayedAt = .distantPast
        aggregator.setStatusBanner("ローカル音声認識を準備中…")
        publishSubtitles()

        do {
            try await speechService.start()
            guard lifecycleGeneration == generation, state == .connecting else {
                await speechService.stop()
                return
            }
            state = .listening
            aggregator.setStatusBanner("録音中… 話してください")
            startTicker(intervalNanoseconds: activeTickerIntervalNanoseconds)
            publishSubtitles()
        } catch is CancellationError {
            guard lifecycleGeneration == generation, state == .connecting else { return }
            aggregator.setStatusBanner(nil)
            state = .idle
            publishSubtitles()
        } catch {
            guard lifecycleGeneration == generation, state == .connecting else { return }
            enterError(error)
        }
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard state != .idle else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop()
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop() async {
        lifecycleGeneration += 1
        state = .closing
        aggregator.setStatusBanner("録音を終了中…")
        publishSubtitles()

        cancelTransientWork()

        await speechService.stop()
        if let finalTranslationWorker {
            await finalTranslationWorker.value
        }

        let snapshot = aggregator.forceFinalize()
        delegate?.interpretationSession(self, didUpdateSubtitles: snapshot)
        aggregator.setStatusBanner(nil)
        state = .idle
        publishSubtitles()
        // 確定字幕は次の発話開始(または再録音)まで残す。タイマー消去はしない。
        stopTicker()
    }

    /// 発話途中の一時的な処理(表示スロットリング待ちの原文とlive翻訳)を打ち切る。
    /// 開始時と停止時の両方から呼び、開始/停止で対称にリセットする。
    private func cancelTransientWork() {
        transcriptionRenderTask?.cancel()
        transcriptionRenderTask = nil
        pendingTranscription = nil
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
    }

    private func handleTranscription(
        text: String,
        language: SpokenLanguage,
        isFinal: Bool
    ) {
        let acceptsTranscription = state == .listening || (state == .closing && isFinal)
        guard acceptsTranscription, language != .unknown else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            retractTranscription(language: language)
            return
        }
        let pending = PendingTranscription(
            text: text,
            language: language,
            isFinal: isFinal
        )

        if isFinal {
            transcriptionRenderTask?.cancel()
            transcriptionRenderTask = nil
            pendingTranscription = nil
            renderTranscription(pending)
            return
        }

        pendingTranscription = pending
        guard transcriptionRenderTask == nil else { return }

        let elapsed = Date().timeIntervalSince(lastTranscriptionRenderedAt)
        let delay = max(0, Self.transcriptionRenderInterval - elapsed)
        transcriptionRenderTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.transcriptionRenderTask = nil
            guard let pending = self.pendingTranscription else { return }
            self.pendingTranscription = nil
            self.renderTranscription(pending)
        }
    }

    private func retractTranscription(language: SpokenLanguage) {
        let retractsPending = pendingTranscription?.language == language
        let retractsCurrent = currentUtterance.language == language
        guard retractsPending || retractsCurrent else { return }

        if retractsPending {
            transcriptionRenderTask?.cancel()
            transcriptionRenderTask = nil
            pendingTranscription = nil
        }
        guard retractsCurrent else { return }

        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        currentUtterance.retract()
        publishCurrentUtterance(isTranslationCurrent: false)
    }

    private func renderTranscription(_ transcription: PendingTranscription) {
        let text = transcription.text
        let language = transcription.language
        let isFinal = transcription.isFinal
        guard text != currentUtterance.sourceText || isFinal else { return }
        lastTranscriptionRenderedAt = Date()

        let generation = currentUtterance.updateSource(text, language: language)
        liveTranslationTask?.cancel()
        liveTranslationTask = nil

        if state == .listening {
            aggregator.setStatusBanner(nil)
        }
        publishCurrentUtterance(isTranslationCurrent: false)

        if isFinal {
            enqueueFinalTranslation(
                sourceText: text,
                language: language,
                sourceGeneration: generation
            )
            return
        }

        liveTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.liveTranslationDebounceNanoseconds)
            guard !Task.isCancelled else { return }

            do {
                let translated = try await self.translationService.translate(
                    text,
                    from: language,
                    priority: .live
                )
                guard !Task.isCancelled else { return }

                // 前回のlive訳表示から最低保持時間が経つまで書き換えを待つ。
                // 待機中に原文が更新されればこのタスクごとキャンセルされ、
                // 中間の訳文は表示せず次の(より長い)訳文へ進む。
                let elapsed = Date().timeIntervalSince(self.lastLiveTranslationDisplayedAt)
                let holdRemaining = self.liveTranslationDisplayHoldInterval - elapsed
                if holdRemaining > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(holdRemaining * 1_000_000_000)
                    )
                    guard !Task.isCancelled else { return }
                }
                guard self.currentUtterance.applyTranslation(
                    translated,
                    generation: generation,
                    sourceText: text
                ) else {
                    return
                }

                self.lastLiveTranslationDisplayedAt = Date()
                self.publishCurrentUtterance(isTranslationCurrent: true)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.currentUtterance.generation else { return }
                self.aggregator.setStatusBanner("ローカル翻訳を準備中…")
                self.publishSubtitles()
                AppLogger.general.error(
                    "Local translation failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func enqueueFinalTranslation(
        sourceText: String,
        language: SpokenLanguage,
        sourceGeneration: Int
    ) {
        guard finalTranslationQueue.count < maxPendingFinalTranslations else {
            aggregator.setStatusBanner("確定翻訳の待機件数が上限に達しました")
            publishSubtitles()
            AppLogger.general.error(
                "Final translation queue is full; dropping newest finalized sentence"
            )
            return
        }
        finalTranslationQueue.append(
            FinalTranslationRequest(
                sourceText: sourceText,
                language: language,
                sourceGeneration: sourceGeneration,
                attemptCount: 0
            )
        )
        guard finalTranslationWorker == nil else { return }

        finalTranslationWorker = Task { @MainActor [weak self] in
            await self?.processFinalTranslationQueue()
        }
    }

    private func processFinalTranslationQueue() async {
        defer { finalTranslationWorker = nil }

        while !finalTranslationQueue.isEmpty {
            let request = finalTranslationQueue.removeFirst()
            do {
                // 翻訳器への入力だけを正規化する。画面の原文は認識結果のまま残す。
                let translationSource = TranslationSourceNormalizer
                    .normalizeForFinalTranslation(
                        request.sourceText,
                        language: request.language
                    )
                let translated = try await translationService.translate(
                    translationSource,
                    from: request.language,
                    priority: .final
                )
                let clearsCurrent =
                    request.sourceGeneration == currentUtterance.generation

                // 未翻訳echoは確定表示しない(原文だけの確定はAGENTS.mdの不変条件違反)。
                // 同じ入力を再翻訳しても同じechoが返るため、リトライもしない。
                if TranslationEchoDetector.isEcho(
                    source: request.sourceText,
                    translated: translated
                ) {
                    AppLogger.general.notice(
                        "Dropping untranslated echo pair from final translation"
                    )
                    if clearsCurrent {
                        currentUtterance.clearContent()
                        aggregator.replaceCurrent(
                            sourceText: "",
                            translatedText: "",
                            isTranslationCurrent: false,
                            canFinalize: false
                        )
                        publishSubtitles()
                    }
                    continue
                }

                if clearsCurrent {
                    currentUtterance.clearContent()
                }
                let finalized = aggregator.finalizePair(
                    sourceText: request.sourceText,
                    translatedText: translated,
                    clearCurrent: clearsCurrent
                )
                delegate?.interpretationSession(
                    self,
                    didUpdateSubtitles: finalized
                )
            } catch is CancellationError {
                if Task.isCancelled {
                    finalTranslationQueue.removeAll()
                    return
                }
                // Request-level cancellation (for example translation session restart)
                // should not abandon later finals already queued behind this one.
                continue
            } catch {
                aggregator.setStatusBanner("ローカル翻訳を準備中…")
                publishSubtitles()
                AppLogger.general.error(
                    "Final local translation failed: \(error.localizedDescription, privacy: .public)"
                )

                let nextAttemptCount = request.attemptCount + 1
                guard nextAttemptCount < maxFinalTranslationAttempts else {
                    AppLogger.general.error(
                        "Final local translation exhausted retries; dropping finalized sentence"
                    )
                    continue
                }

                var retryRequest = request
                retryRequest.attemptCount = nextAttemptCount
                finalTranslationQueue.insert(retryRequest, at: 0)

                if finalTranslationRetryDelayNanoseconds > 0 {
                    try? await Task.sleep(
                        nanoseconds: finalTranslationRetryDelayNanoseconds
                    )
                }
                if Task.isCancelled {
                    finalTranslationQueue.removeAll()
                    return
                }
            }
        }
    }

    private func startTicker(intervalNanoseconds: UInt64) {
        stopTicker()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled else { return }
                let snapshot = self.aggregator.tick()
                self.delegate?.interpretationSession(self, didUpdateSubtitles: snapshot)
                if self.state == .idle || self.state == .error {
                    self.tickerTask = nil
                    return
                }
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func publishCurrentUtterance(isTranslationCurrent: Bool) {
        // 現在訳だけを確定可能にする。旧訳文の参考表示は canFinalize=false のまま残し、
        // 停止時 forceFinalize が完全な live ペアを誤って破棄しないようにする。
        let snapshot = aggregator.replaceCurrent(
            sourceText: currentUtterance.sourceText,
            translatedText: currentUtterance.translatedText,
            isTranslationCurrent: isTranslationCurrent,
            canFinalize: isTranslationCurrent
        )
        delegate?.interpretationSession(self, didUpdateSubtitles: snapshot)
    }

    private func publishSubtitles() {
        delegate?.interpretationSession(self, didUpdateSubtitles: aggregator.snapshot())
    }

    private func enterError(_ error: Error) {
        state = .error
        aggregator.setStatusBanner(error.localizedDescription)
        publishSubtitles()
        delegate?.interpretationSession(self, didEncounterMessage: error.localizedDescription)
    }
}

extension InterpretationSession: LocalSpeechRecognitionServiceDelegate {
    func localSpeechRecognitionService(
        didUpdate text: String,
        language: SpokenLanguage,
        isFinal: Bool
    ) {
        handleTranscription(text: text, language: language, isFinal: isFinal)
    }

    func localSpeechRecognitionService(
        didUpdateStatus message: String
    ) {
        aggregator.setStatusBanner(message)
        publishSubtitles()
    }

    func localSpeechRecognitionService(
        didFail error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.state != .closing else { return }
            await self.stop()
            guard self.state == .idle else { return }
            self.enterError(error)
        }
    }
}
