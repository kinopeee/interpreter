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
    private struct PendingTranscription {
        let text: String
        let language: SpokenLanguage
        let isFinal: Bool
    }

    private struct CurrentUtterance {
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
    }

    weak var delegate: InterpretationSessionDelegate?

    private let speechService: any LocalSpeechRecognitionServicing
    private let translationService: any LocalTranslationServicing
    private let aggregator: SubtitleAggregator
    private let maxPendingFinalTranslations: Int
    private let activeTickerIntervalNanoseconds: UInt64
    private let idleTickerIntervalNanoseconds: UInt64

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
    private var lifecycleGeneration = 0
    private var currentUtterance = CurrentUtterance()

    init(
        translationService: any LocalTranslationServicing,
        speechService: any LocalSpeechRecognitionServicing = LocalSpeechRecognitionService(),
        aggregator: SubtitleAggregator = SubtitleAggregator(),
        maxPendingFinalTranslations: Int = 32,
        activeTickerIntervalNanoseconds: UInt64 = 200_000_000,
        idleTickerIntervalNanoseconds: UInt64 = 200_000_000
    ) {
        precondition(maxPendingFinalTranslations > 0)
        self.translationService = translationService
        self.speechService = speechService
        self.aggregator = aggregator
        self.maxPendingFinalTranslations = maxPendingFinalTranslations
        self.activeTickerIntervalNanoseconds = activeTickerIntervalNanoseconds
        self.idleTickerIntervalNanoseconds = idleTickerIntervalNanoseconds
        speechService.delegate = self
    }

    func start() async {
        guard state == .idle || state == .error else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        state = .connecting
        aggregator.reset()
        transcriptionRenderTask?.cancel()
        transcriptionRenderTask = nil
        pendingTranscription = nil
        currentUtterance.reset()
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        finalTranslationQueue.removeAll()
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

        transcriptionRenderTask?.cancel()
        transcriptionRenderTask = nil
        pendingTranscription = nil
        liveTranslationTask?.cancel()
        liveTranslationTask = nil

        await speechService.stop()
        if let finalTranslationWorker {
            await finalTranslationWorker.value
        }

        let snapshot = aggregator.forceFinalize()
        delegate?.interpretationSession(self, didUpdateSubtitles: snapshot)
        aggregator.setStatusBanner(nil)
        state = .idle
        publishSubtitles()
        if snapshot.previous == nil {
            stopTicker()
        } else {
            startTicker(intervalNanoseconds: idleTickerIntervalNanoseconds)
        }
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
        let delay = max(0, 0.16 - elapsed)
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
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let translated = try await self.translationService.translate(
                    text,
                    from: language,
                    priority: .live
                )
                guard !Task.isCancelled,
                      self.currentUtterance.applyTranslation(
                          translated,
                          generation: generation,
                          sourceText: text
                      )
                else {
                    return
                }

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
                sourceGeneration: sourceGeneration
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
                let translated = try await translationService.translate(
                    request.sourceText,
                    from: request.language,
                    priority: .final
                )
                let clearsCurrent =
                    request.sourceGeneration == currentUtterance.generation
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
                continue
            } catch {
                aggregator.setStatusBanner("ローカル翻訳を準備中…")
                publishSubtitles()
                AppLogger.general.error(
                    "Final local translation failed: \(error.localizedDescription, privacy: .public)"
                )
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
                if (self.state == .idle || self.state == .error),
                   snapshot.current.isEmpty,
                   snapshot.previous == nil
                {
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
        let snapshot = aggregator.replaceCurrent(
            sourceText: currentUtterance.sourceText,
            translatedText: currentUtterance.translatedText,
            isTranslationCurrent: isTranslationCurrent,
            canFinalize: false
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
