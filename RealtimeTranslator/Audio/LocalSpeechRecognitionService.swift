@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

enum LocalSpeechRecognitionError: Error, LocalizedError, Sendable {
    case microphoneDenied
    case speechRecognitionDenied
    case speechTranscriberUnavailable
    case localeUnsupported(String)
    case audioFormatUnavailable
    case audioConverterUnavailable
    case audioBufferPoolUnavailable
    case modelInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "マイクを利用できません"
        case .speechRecognitionDenied:
            return "音声認識を利用できません"
        case .speechTranscriberUnavailable:
            return "このMacではローカル音声認識を利用できません"
        case .localeUnsupported(let locale):
            return "ローカル音声認識が \(locale) に対応していません"
        case .audioFormatUnavailable:
            return "音声認識用の音声形式を取得できません"
        case .audioConverterUnavailable:
            return "音声認識用の音声変換を開始できません"
        case .audioBufferPoolUnavailable:
            return "音声認識用の音声バッファを準備できません"
        case .modelInstallationFailed(let message):
            return "音声認識モデルを準備できません: \(message)"
        }
    }
}

private enum SpeechAuthorization {
    static func request() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                let callback: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = {
                    status in
                    continuation.resume(returning: status == .authorized)
                }
                SFSpeechRecognizer.requestAuthorization(callback)
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

@MainActor
protocol LocalSpeechRecognitionServicing: AnyObject {
    var delegate: LocalSpeechRecognitionServiceDelegate? { get set }
    func start() async throws
    func stop() async
}

@MainActor
protocol LocalSpeechRecognitionServiceDelegate: AnyObject {
    func localSpeechRecognitionService(
        didUpdate text: String,
        language: SpokenLanguage,
        isFinal: Bool
    )
    func localSpeechRecognitionService(
        didUpdateStatus message: String
    )
    func localSpeechRecognitionService(
        didFail error: Error
    )
}

@MainActor
private struct RunningSpeechPipeline {
    let analyzer: SpeechAnalyzer
    let japaneseTranscriber: SpeechTranscriber
    let englishTranscriber: SpeechTranscriber
    let captureContinuation: AsyncStream<CapturedAudioBuffer>.Continuation
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    let feederTask: Task<Void, Never>
    let resultTasks: [Task<Void, Never>]
    let audioConverter: AnalyzerAudioConverter
}

@MainActor
private final class SpeechStartupResources {
    var analyzer: SpeechAnalyzer?
    var japaneseTranscriber: SpeechTranscriber?
    var englishTranscriber: SpeechTranscriber?
    var captureContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    var feederTask: Task<Void, Never>?
    var resultTasks: [Task<Void, Never>] = []
    var audioConverter: AnalyzerAudioConverter?
    var isTapInstalled = false

    func promoteToRunning() -> RunningSpeechPipeline {
        guard let analyzer,
              let japaneseTranscriber,
              let englishTranscriber,
              let captureContinuation,
              let inputContinuation,
              let feederTask,
              let audioConverter,
              !resultTasks.isEmpty,
              isTapInstalled
        else {
            preconditionFailure("Incomplete speech startup resources")
        }

        let pipeline = RunningSpeechPipeline(
            analyzer: analyzer,
            japaneseTranscriber: japaneseTranscriber,
            englishTranscriber: englishTranscriber,
            captureContinuation: captureContinuation,
            inputContinuation: inputContinuation,
            feederTask: feederTask,
            resultTasks: resultTasks,
            audioConverter: audioConverter
        )
        self.analyzer = nil
        self.japaneseTranscriber = nil
        self.englishTranscriber = nil
        self.captureContinuation = nil
        self.inputContinuation = nil
        self.feederTask = nil
        resultTasks.removeAll()
        self.audioConverter = nil
        isTapInstalled = false
        return pipeline
    }
}

@MainActor
private struct PreparedSpeechModules {
    let japaneseTranscriber: SpeechTranscriber
    let englishTranscriber: SpeechTranscriber
    let modules: [any SpeechModule]
}

@MainActor
private struct AudioCaptureConfiguration {
    let inputNode: AVAudioInputNode
    let inputFormat: AVAudioFormat
    let converter: AnalyzerAudioConverter
    let bufferPool: CapturedAudioBufferPool
    let tapBufferSize: AVAudioFrameCount
    let bufferPoolCapacity: Int
}

@MainActor
final class LocalSpeechRecognitionService: LocalSpeechRecognitionServicing {
    private enum LifecycleState: Equatable {
        case idle
        case starting(Int)
        case running(Int)
        case stopping(Int)
    }

    weak var delegate: LocalSpeechRecognitionServiceDelegate?

    private let audioEngine = AVAudioEngine()
    private var runningPipeline: RunningSpeechPipeline?
    private var speechArbiter = BilingualSpeechArbiter()
    private var languageSelectionTask: Task<Void, Never>?
    private var languageSelectionTaskGeneration = 0
    private var lastEmittedSignature: String?
    private var lifecycleState: LifecycleState = .idle
    private var lifecycleGeneration = 0
    private var acceptedResultGeneration: Int?
    private(set) var isRunning = false

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async throws {
        guard lifecycleState == .idle else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        lifecycleState = .starting(generation)
        let startupResources = SpeechStartupResources()

        do {
            try await authorizeStartup(generation: generation)
            let preparedModules = try await prepareSpeechModules(
                generation: generation,
                resources: startupResources
            )

            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: preparedModules.modules
            )
            try ensureStartupIsCurrent(generation)
            guard let analyzerFormat else {
                throw LocalSpeechRecognitionError.audioFormatUnavailable
            }
            let captureConfiguration = try makeAudioCaptureConfiguration(
                analyzerFormat: analyzerFormat
            )
            try await startAudioPipeline(
                preparedModules: preparedModules,
                analyzerFormat: analyzerFormat,
                captureConfiguration: captureConfiguration,
                generation: generation,
                resources: startupResources
            )

            runningPipeline = startupResources.promoteToRunning()
            speechArbiter.reset()
            cancelLanguageSelectionTask()
            lastEmittedSignature = nil
            acceptedResultGeneration = generation
            isRunning = true
            lifecycleState = .running(generation)
            delegate?.localSpeechRecognitionService(
                didUpdateStatus: "録音中… 話してください"
            )
        } catch {
            await cleanUpFailedStart(startupResources)
            if isStartupCurrent(generation) {
                isRunning = false
                lifecycleState = .idle
            }
            throw error
        }
    }

    func stop() async {
        switch lifecycleState {
        case .idle, .stopping:
            return
        case .starting, .running:
            break
        }

        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        lifecycleState = .stopping(generation)
        isRunning = false

        let pipeline = runningPipeline
        runningPipeline = nil
        if pipeline != nil {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine.stop()
        pipeline?.captureContinuation.finish()
        if let pipeline {
            await pipeline.feederTask.value
            try? await pipeline.analyzer.finalizeAndFinishThroughEndOfInput()
        }

        for task in pipeline?.resultTasks ?? [] {
            await task.value
        }
        let languageSelectionTask = self.languageSelectionTask
        cancelLanguageSelectionTask()
        if let languageSelectionTask {
            await languageSelectionTask.value
        }
        acceptedResultGeneration = nil
        speechArbiter.reset()
        lastEmittedSignature = nil
        if lifecycleState == .stopping(generation) {
            lifecycleState = .idle
        }
    }

    private func authorizeStartup(generation: Int) async throws {
        let microphoneGranted = await requestPermission()
        try ensureStartupIsCurrent(generation)
        guard microphoneGranted else {
            throw LocalSpeechRecognitionError.microphoneDenied
        }

        let speechRecognitionGranted = await SpeechAuthorization.request()
        try ensureStartupIsCurrent(generation)
        guard speechRecognitionGranted else {
            throw LocalSpeechRecognitionError.speechRecognitionDenied
        }
    }

    private func prepareSpeechModules(
        generation: Int,
        resources: SpeechStartupResources
    ) async throws -> PreparedSpeechModules {
        guard SpeechTranscriber.isAvailable else {
            throw LocalSpeechRecognitionError.speechTranscriberUnavailable
        }
        delegate?.localSpeechRecognitionService(
            didUpdateStatus: "日英音声認識モデルを確認中…"
        )

        let japaneseLocale = try await supportedLocale(identifier: "ja-JP")
        try ensureStartupIsCurrent(generation)
        let englishLocale = try await supportedLocale(identifier: "en-US")
        try ensureStartupIsCurrent(generation)

        let japaneseTranscriber = makeTranscriber(locale: japaneseLocale)
        let englishTranscriber = makeTranscriber(locale: englishLocale)
        resources.japaneseTranscriber = japaneseTranscriber
        resources.englishTranscriber = englishTranscriber
        let prepared = PreparedSpeechModules(
            japaneseTranscriber: japaneseTranscriber,
            englishTranscriber: englishTranscriber,
            modules: [japaneseTranscriber, englishTranscriber]
        )

        do {
            let request = try await AssetInventory.assetInstallationRequest(
                supporting: prepared.modules
            )
            try ensureStartupIsCurrent(generation)
            if let request {
                delegate?.localSpeechRecognitionService(
                    didUpdateStatus: "日英音声認識モデルをダウンロード中…"
                )
                try await request.downloadAndInstall()
                try ensureStartupIsCurrent(generation)
            }
        } catch {
            guard isStartupCurrent(generation), !(error is CancellationError) else {
                throw CancellationError()
            }
            throw LocalSpeechRecognitionError.modelInstallationFailed(
                error.localizedDescription
            )
        }
        return prepared
    }

    private func makeAudioCaptureConfiguration(
        analyzerFormat: AVAudioFormat
    ) throws -> AudioCaptureConfiguration {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LocalSpeechRecognitionError.audioFormatUnavailable
        }
        guard let converter = AnalyzerAudioConverter(
            inputFormat: inputFormat,
            outputFormat: analyzerFormat
        ) else {
            throw LocalSpeechRecognitionError.audioConverterUnavailable
        }

        let tapBufferSize: AVAudioFrameCount = 4096
        let captureFrameCapacity = max(
            tapBufferSize,
            AVAudioFrameCount(inputFormat.sampleRate.rounded(.up))
        )
        let bufferPoolCapacity = 64
        guard let bufferPool = CapturedAudioBufferPool(
            format: inputFormat,
            frameCapacity: captureFrameCapacity,
            capacity: bufferPoolCapacity
        ) else {
            throw LocalSpeechRecognitionError.audioBufferPoolUnavailable
        }
        return AudioCaptureConfiguration(
            inputNode: inputNode,
            inputFormat: inputFormat,
            converter: converter,
            bufferPool: bufferPool,
            tapBufferSize: tapBufferSize,
            bufferPoolCapacity: bufferPoolCapacity
        )
    }

    private func startAudioPipeline(
        preparedModules: PreparedSpeechModules,
        analyzerFormat: AVAudioFormat,
        captureConfiguration: AudioCaptureConfiguration,
        generation: Int,
        resources: SpeechStartupResources
    ) async throws {
        resources.audioConverter = captureConfiguration.converter
        let analyzer = SpeechAnalyzer(modules: preparedModules.modules)
        resources.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try ensureStartupIsCurrent(generation)

        let (captureStream, captureContinuation) =
            AsyncStream<CapturedAudioBuffer>.makeStream(
                bufferingPolicy: .bufferingNewest(
                    captureConfiguration.bufferPoolCapacity - 2
                )
            )
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        resources.captureContinuation = captureContinuation
        resources.inputContinuation = inputContinuation

        try await analyzer.start(inputSequence: inputStream)
        try ensureStartupIsCurrent(generation)

        resources.resultTasks = makeResultTasks(
            japaneseTranscriber: preparedModules.japaneseTranscriber,
            englishTranscriber: preparedModules.englishTranscriber,
            generation: generation
        )
        resources.feederTask = makeFeederTask(
            captureStream: captureStream,
            inputContinuation: inputContinuation,
            converter: captureConfiguration.converter,
            generation: generation
        )

        let audioTap = AnalyzerAudioTap(
            continuation: captureContinuation,
            bufferPool: captureConfiguration.bufferPool
        )
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            audioTap.receive(buffer)
        }
        captureConfiguration.inputNode.removeTap(onBus: 0)
        captureConfiguration.inputNode.installTap(
            onBus: 0,
            bufferSize: captureConfiguration.tapBufferSize,
            format: captureConfiguration.inputFormat,
            block: tapBlock
        )
        resources.isTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        try ensureStartupIsCurrent(generation)
    }

    private func makeFeederTask(
        captureStream: AsyncStream<CapturedAudioBuffer>,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        converter: AnalyzerAudioConverter,
        generation: Int
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { inputContinuation.finish() }

            do {
                for await captured in captureStream {
                    defer { captured.release() }
                    try Task.checkCancellation()
                    let converted = try converter.convert(captured.buffer)
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                }
            } catch is CancellationError {
                return
            } catch {
                AppLogger.audio.error(
                    "Audio feeder failed: \(error.localizedDescription, privacy: .public)"
                )
                await self?.reportPipelineFailure(error, generation: generation)
            }
        }
    }

    private func ensureStartupIsCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isStartupCurrent(generation) else {
            throw CancellationError()
        }
    }

    private func isStartupCurrent(_ generation: Int) -> Bool {
        lifecycleGeneration == generation
            && lifecycleState == .starting(generation)
    }

    private func cleanUpFailedStart(_ resources: SpeechStartupResources) async {
        if resources.isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            resources.isTapInstalled = false
        }
        resources.captureContinuation?.finish()
        resources.captureContinuation = nil
        resources.feederTask?.cancel()
        if let feederTask = resources.feederTask {
            await feederTask.value
        }
        resources.feederTask = nil
        resources.inputContinuation?.finish()
        resources.inputContinuation = nil
        if let analyzer = resources.analyzer {
            await analyzer.cancelAndFinishNow()
        }
        resources.analyzer = nil
        for task in resources.resultTasks {
            task.cancel()
            await task.value
        }
        resources.resultTasks.removeAll()
        resources.japaneseTranscriber = nil
        resources.englishTranscriber = nil
        resources.audioConverter = nil
    }

    private func reportPipelineFailure(_ error: Error, generation: Int) {
        guard case .running = lifecycleState,
              acceptedResultGeneration == generation
        else {
            return
        }
        delegate?.localSpeechRecognitionService(didFail: error)
    }

    private func supportedLocale(identifier: String) async throws -> Locale {
        let requested = Locale(identifier: identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw LocalSpeechRecognitionError.localeUnsupported(identifier)
        }
        return locale
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
    }

    private func makeResultTasks(
        japaneseTranscriber: SpeechTranscriber,
        englishTranscriber: SpeechTranscriber,
        generation: Int
    ) -> [Task<Void, Never>] {
        [
            makeResultTask(
                transcriber: japaneseTranscriber,
                language: .japanese,
                generation: generation
            ),
            makeResultTask(
                transcriber: englishTranscriber,
                language: .english,
                generation: generation
            ),
        ]
    }

    private func makeResultTask(
        transcriber: SpeechTranscriber,
        language: SpokenLanguage,
        generation: Int
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(
                        result: result,
                        language: language,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.reportPipelineFailure(error, generation: generation)
            }
        }
    }

    private func handle(
        result: SpeechTranscriber.Result,
        language: SpokenLanguage,
        generation: Int
    ) {
        guard acceptedResultGeneration == generation else { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)

        let confidenceValues = result.text.runs.compactMap(\.transcriptionConfidence)
        let confidence = confidenceValues.isEmpty
            ? 0.5
            : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        let candidate = SpeechRecognitionCandidate(
            text: text,
            language: language,
            confidence: confidence,
            isFinal: result.isFinal,
            startTime: result.range.start.seconds,
            endTime: result.range.end.seconds
        )
        if let winner = speechArbiter.submit(candidate) {
            cancelLanguageSelectionTask()
            emit(winner)
        }
        scheduleLanguageSelectionIfNeeded()
    }

    private func scheduleLanguageSelectionIfNeeded() {
        guard speechArbiter.activeLanguage == nil,
              speechArbiter.hasPendingCandidates,
              languageSelectionTask == nil,
              let generation = acceptedResultGeneration
        else {
            return
        }

        languageSelectionTaskGeneration += 1
        let taskGeneration = languageSelectionTaskGeneration
        languageSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.languageSelectionTaskGeneration == taskGeneration {
                    self.languageSelectionTask = nil
                }
            }

            try? await Task.sleep(nanoseconds: 180_000_000)
            while !Task.isCancelled {
                guard !Task.isCancelled,
                      self.acceptedResultGeneration == generation,
                      self.speechArbiter.activeLanguage == nil,
                      self.speechArbiter.hasPendingCandidates,
                      let winner = self.speechArbiter.selectBestAvailable()
                else {
                    return
                }
                self.emit(winner)
            }
        }
    }

    private func cancelLanguageSelectionTask() {
        languageSelectionTaskGeneration += 1
        languageSelectionTask?.cancel()
        languageSelectionTask = nil
    }

    private func emit(_ candidate: SpeechRecognitionCandidate) {
        let signature = [
            String(describing: candidate.language),
            String(candidate.isFinal),
            String(candidate.startTime),
            String(candidate.endTime),
            candidate.text,
        ].joined(separator: "|")
        guard signature != lastEmittedSignature else { return }
        lastEmittedSignature = signature

        delegate?.localSpeechRecognitionService(
            didUpdate: candidate.text,
            language: candidate.language,
            isFinal: candidate.isFinal
        )
    }
}
