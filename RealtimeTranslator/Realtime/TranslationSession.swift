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

    weak var delegate: InterpretationSessionDelegate?

    private let speechService = LocalSpeechRecognitionService()
    private let translationService: LocalTranslationService
    private let aggregator = SubtitleAggregator()

    private(set) var state: TranslationState = .idle {
        didSet {
            guard oldValue != state else { return }
            delegate?.interpretationSession(self, didUpdateState: state)
        }
    }

    private var tickerTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var transcriptionRenderTask: Task<Void, Never>?
    private var pendingTranscription: PendingTranscription?
    private var lastTranscriptionRenderedAt = Date.distantPast
    private var translationGeneration = 0
    private var currentSourceText = ""
    private var currentTranslationText = ""
    private var currentLanguage: SpokenLanguage = .unknown

    init(translationService: LocalTranslationService) {
        self.translationService = translationService
        speechService.delegate = self
    }

    func start() async {
        guard state == .idle || state == .error else { return }
        state = .connecting
        aggregator.reset()
        transcriptionRenderTask?.cancel()
        transcriptionRenderTask = nil
        pendingTranscription = nil
        currentSourceText = ""
        currentTranslationText = ""
        currentLanguage = .unknown
        aggregator.setStatusBanner("ローカル音声認識を準備中…")
        publishSubtitles()

        do {
            try await speechService.start()
            state = .listening
            aggregator.setStatusBanner("録音中… 話してください")
            startTicker()
            publishSubtitles()
        } catch {
            enterError(error)
        }
    }

    func stop() async {
        guard state != .idle else { return }
        state = .closing
        aggregator.setStatusBanner("録音を終了中…")
        publishSubtitles()

        await speechService.stop()
        transcriptionRenderTask?.cancel()
        transcriptionRenderTask = nil
        pendingTranscription = nil
        translationTask?.cancel()
        translationTask = nil
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
        guard state == .listening, language != .unknown else { return }
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

        translationGeneration += 1
        let generation = translationGeneration
        let preservesTranslation = language == currentLanguage
            && !currentTranslationText.isEmpty
            && !currentSourceText.isEmpty
        if !preservesTranslation {
            currentTranslationText = ""
        }
        currentSourceText = text
        currentLanguage = language
        translationTask?.cancel()

        aggregator.setStatusBanner(nil)
        let sourceSnapshot = aggregator.replaceCurrent(
            sourceText: text,
            translatedText: currentTranslationText,
            isTranslationCurrent: false,
            canFinalize: false
        )
        delegate?.interpretationSession(self, didUpdateSubtitles: sourceSnapshot)

        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !isFinal {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }

            do {
                let translated = try await self.translationService.translate(
                    text,
                    from: language,
                    priority: isFinal ? .final : .live
                )
                guard !Task.isCancelled, generation == self.translationGeneration else {
                    return
                }

                self.currentTranslationText = translated
                let snapshot = self.aggregator.replaceCurrent(
                    sourceText: self.currentSourceText,
                    translatedText: translated,
                    isTranslationCurrent: true,
                    canFinalize: isFinal
                )
                if isFinal {
                    let finalized = self.aggregator.forceFinalize()
                    self.currentSourceText = ""
                    self.currentTranslationText = ""
                    self.currentLanguage = .unknown
                    self.delegate?.interpretationSession(
                        self,
                        didUpdateSubtitles: finalized
                    )
                } else {
                    self.delegate?.interpretationSession(
                        self,
                        didUpdateSubtitles: snapshot
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.translationGeneration else { return }
                self.aggregator.setStatusBanner("ローカル翻訳を準備中…")
                self.publishSubtitles()
                AppLogger.general.error(
                    "Local translation failed: \(error.localizedDescription, privacy: .public)"
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
        _ service: LocalSpeechRecognitionService,
        didUpdate text: String,
        language: SpokenLanguage,
        isFinal: Bool
    ) {
        handleTranscription(text: text, language: language, isFinal: isFinal)
    }

    func localSpeechRecognitionService(
        _ service: LocalSpeechRecognitionService,
        didUpdateStatus message: String
    ) {
        aggregator.setStatusBanner(message)
        publishSubtitles()
    }

    func localSpeechRecognitionService(
        _ service: LocalSpeechRecognitionService,
        didFail error: Error
    ) {
        enterError(error)
        Task { await stop() }
    }
}
