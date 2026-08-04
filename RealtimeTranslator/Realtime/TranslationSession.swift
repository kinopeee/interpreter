import Foundation

enum InterpretationSessionError: Error, LocalizedError, Sendable {
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "録音はすでに開始されています"
        }
    }
}

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

/// Fully on-device speech recognition and translation session.
@MainActor
final class InterpretationSession {
    private struct PendingTranscription {
        let text: String
        let language: SpokenLanguage
        let isFinal: Bool
    }

    private struct FinalTranslationRequest {
        let sourceText: String
        let language: SpokenLanguage
        let sourceGeneration: Int
    }

    weak var delegate: InterpretationSessionDelegate?

    private let speechService: any LocalSpeechRecognitionServicing
    private let translationService: any LocalTranslationServicing
    private let aggregator = SubtitleAggregator()

    private(set) var state: TranslationState = .idle {
        didSet {
            guard oldValue != state else { return }
            delegate?.interpretationSession(self, didUpdateState: state)
        }
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
    private var sourceGeneration = 0
    private var currentSourceText = ""
    private var currentTranslationText = ""
    private var currentLanguage: SpokenLanguage = .unknown

    init(
        translationService: any LocalTranslationServicing,
        speechService: any LocalSpeechRecognitionServicing = LocalSpeechRecognitionService()
    ) {
        self.translationService = translationService
        self.speechService = speechService
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
        currentSourceText = ""
        currentTranslationText = ""
        currentLanguage = .unknown
        sourceGeneration = 0
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
            startTicker()
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
        stopTicker()

        let snapshot = aggregator.forceFinalize()
        delegate?.interpretationSession(self, didUpdateSubtitles: snapshot)
        aggregator.setStatusBanner(nil)
        state = .idle
        publishSubtitles()
    }

    private func handleTranscription(
        text: String,
        language: SpokenLanguage,
        isFinal: Bool
    ) {
        let acceptsTranscription = state == .listening || (state == .closing && isFinal)
        guard acceptsTranscription, language != .unknown else { return }
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

    private func renderTranscription(_ transcription: PendingTranscription) {
        let text = transcription.text
        let language = transcription.language
        let isFinal = transcription.isFinal
        guard text != currentSourceText || isFinal else { return }
        lastTranscriptionRenderedAt = Date()

        sourceGeneration += 1
        let generation = sourceGeneration
        let preservesTranslation = language == currentLanguage
            && !currentTranslationText.isEmpty
            && !currentSourceText.isEmpty
        if !preservesTranslation {
            currentTranslationText = ""
        }
        currentSourceText = text
        currentLanguage = language
        liveTranslationTask?.cancel()
        liveTranslationTask = nil

        if state == .listening {
            aggregator.setStatusBanner(nil)
        }
        let sourceSnapshot = aggregator.replaceCurrent(
            sourceText: text,
            translatedText: currentTranslationText,
            isTranslationCurrent: false,
            canFinalize: false
        )
        delegate?.interpretationSession(self, didUpdateSubtitles: sourceSnapshot)

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
                      generation == self.sourceGeneration,
                      self.currentSourceText == text
                else {
                    return
                }

                self.currentTranslationText = translated
                let snapshot = self.aggregator.replaceCurrent(
                    sourceText: self.currentSourceText,
                    translatedText: translated,
                    isTranslationCurrent: true,
                    canFinalize: false
                )
                self.delegate?.interpretationSession(
                    self,
                    didUpdateSubtitles: snapshot
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.sourceGeneration else { return }
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
                let clearsCurrent = request.sourceGeneration == sourceGeneration
                if clearsCurrent {
                    currentSourceText = ""
                    currentTranslationText = ""
                    currentLanguage = .unknown
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

    private func startTicker() {
        stopTicker()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                let snapshot = self.aggregator.tick()
                self.delegate?.interpretationSession(self, didUpdateSubtitles: snapshot)
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
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
