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
        case .modelInstallationFailed(let message):
            return "音声認識モデルを準備できません: \(message)"
        }
    }
}

private struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
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

private final class AnalyzerInputProvider: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

private final class AnalyzerAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw LocalSpeechRecognitionError.audioConverterUnavailable
        }

        let provider = AnalyzerInputProvider(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if let buffer = provider.next() {
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw LocalSpeechRecognitionError.audioConverterUnavailable
        }
        return output
    }
}

private final class AnalyzerAudioTap: @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    private let didLogFirstBuffer = OSAllocatedUnfairLock(initialState: false)

    init(continuation: AsyncStream<CapturedAudioBuffer>.Continuation) {
        self.continuation = continuation
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        let isFirstBuffer = didLogFirstBuffer.withLock { didLog in
            guard !didLog else { return false }
            didLog = true
            return true
        }
        if isFirstBuffer {
            AppLogger.audio.info("[debug:C] First audio buffer received off MainActor")
        }

        continuation.yield(CapturedAudioBuffer(buffer: buffer))
    }
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
    private var analyzer: SpeechAnalyzer?
    private var japaneseTranscriber: SpeechTranscriber?
    private var englishTranscriber: SpeechTranscriber?
    private var captureContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var feederTask: Task<Void, Never>?
    private var resultTasks: [Task<Void, Never>] = []
    private var audioConverter: AnalyzerAudioConverter?
    private var speechArbiter = BilingualSpeechArbiter()
    private var languageSelectionTask: Task<Void, Never>?
    private var lastEmittedSignature: String?
    private var lifecycleState: LifecycleState = .idle
    private var lifecycleGeneration = 0
    private var acceptedResultGeneration: Int?
    private var isTapInstalled = false
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

        var startupAnalyzer: SpeechAnalyzer?
        var startupCaptureContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
        var startupInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var startupFeederTask: Task<Void, Never>?
        var startupResultTasks: [Task<Void, Never>] = []
        var startupTapInstalled = false

        do {
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
            let modules: [any SpeechModule] = [japaneseTranscriber, englishTranscriber]

            do {
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: modules
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

            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules
            )
            try ensureStartupIsCurrent(generation)
            guard let analyzerFormat else {
                throw LocalSpeechRecognitionError.audioFormatUnavailable
            }

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

            let analyzer = SpeechAnalyzer(modules: modules)
            startupAnalyzer = analyzer
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try ensureStartupIsCurrent(generation)

            let (captureStream, captureContinuation) =
                AsyncStream<CapturedAudioBuffer>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
            let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(32)
            )
            startupCaptureContinuation = captureContinuation
            startupInputContinuation = continuation

            try await analyzer.start(inputSequence: inputStream)
            try ensureStartupIsCurrent(generation)

            let resultTasks = makeResultTasks(
                japaneseTranscriber: japaneseTranscriber,
                englishTranscriber: englishTranscriber,
                generation: generation
            )
            startupResultTasks = resultTasks

            let feederTask = Task.detached(priority: .userInitiated) { [weak self] in
                defer { continuation.finish() }

                do {
                    for await captured in captureStream {
                        try Task.checkCancellation()
                        let converted = try converter.convert(captured.buffer)
                        continuation.yield(AnalyzerInput(buffer: converted))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    AppLogger.audio.error(
                        "Audio feeder failed: \(error.localizedDescription, privacy: .public)"
                    )
                    await self?.reportAudioFeederFailure(
                        error,
                        generation: generation
                    )
                }
            }
            startupFeederTask = feederTask

            let audioTap = AnalyzerAudioTap(continuation: captureContinuation)
            let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
                audioTap.receive(buffer)
            }
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: inputFormat,
                block: tapBlock
            )
            startupTapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()
            try ensureStartupIsCurrent(generation)

            self.analyzer = analyzer
            self.japaneseTranscriber = japaneseTranscriber
            self.englishTranscriber = englishTranscriber
            self.captureContinuation = captureContinuation
            inputContinuation = continuation
            self.feederTask = feederTask
            self.resultTasks = resultTasks
            audioConverter = converter
            isTapInstalled = true
            speechArbiter.reset()
            languageSelectionTask?.cancel()
            languageSelectionTask = nil
            lastEmittedSignature = nil
            acceptedResultGeneration = generation
            isRunning = true
            lifecycleState = .running(generation)
            delegate?.localSpeechRecognitionService(
                didUpdateStatus: "録音中… 話してください"
            )
        } catch {
            await cleanUpFailedStart(
                analyzer: startupAnalyzer,
                captureContinuation: startupCaptureContinuation,
                inputContinuation: startupInputContinuation,
                feederTask: startupFeederTask,
                resultTasks: startupResultTasks,
                tapInstalled: startupTapInstalled
            )
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

        let analyzer = self.analyzer
        self.analyzer = nil
        let captureContinuation = self.captureContinuation
        self.captureContinuation = nil
        let inputContinuation = self.inputContinuation
        self.inputContinuation = nil
        let feederTask = self.feederTask
        self.feederTask = nil
        let resultTasks = self.resultTasks
        self.resultTasks.removeAll()

        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine.stop()
        captureContinuation?.finish()
        if let feederTask {
            await feederTask.value
        } else {
            inputContinuation?.finish()
        }

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        for task in resultTasks {
            await task.value
        }
        if let languageSelectionTask {
            await languageSelectionTask.value
        }
        languageSelectionTask = nil
        japaneseTranscriber = nil
        englishTranscriber = nil
        audioConverter = nil
        acceptedResultGeneration = nil
        speechArbiter.reset()
        lastEmittedSignature = nil
        if lifecycleState == .stopping(generation) {
            lifecycleState = .idle
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

    private func cleanUpFailedStart(
        analyzer: SpeechAnalyzer?,
        captureContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation?,
        feederTask: Task<Void, Never>?,
        resultTasks: [Task<Void, Never>],
        tapInstalled: Bool
    ) async {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        captureContinuation?.finish()
        feederTask?.cancel()
        if let feederTask {
            await feederTask.value
        }
        inputContinuation?.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        for task in resultTasks {
            task.cancel()
            await task.value
        }
    }

    private func reportAudioFeederFailure(_ error: Error, generation: Int) {
        guard case .running = lifecycleState,
              acceptedResultGeneration == generation
        else {
            return
        }
        delegate?.localSpeechRecognitionService(didFail: error)
    }

    private func reportResultFailure(_ error: Error, generation: Int) {
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
            Task { [weak self] in
                do {
                    for try await result in japaneseTranscriber.results {
                        self?.handle(
                            result: result,
                            language: .japanese,
                            generation: generation
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.reportResultFailure(error, generation: generation)
                }
            },
            Task { [weak self] in
                do {
                    for try await result in englishTranscriber.results {
                        self?.handle(
                            result: result,
                            language: .english,
                            generation: generation
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.reportResultFailure(error, generation: generation)
                }
            },
        ]
    }

    private func handle(
        result: SpeechTranscriber.Result,
        language: SpokenLanguage,
        generation: Int
    ) {
        guard acceptedResultGeneration == generation else { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

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
            languageSelectionTask?.cancel()
            languageSelectionTask = nil
            emit(winner)
            return
        }

        guard speechArbiter.activeLanguage == nil,
              speechArbiter.hasPendingCandidates,
              languageSelectionTask == nil
        else {
            return
        }

        languageSelectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled else { return }
            self.languageSelectionTask = nil
            if let winner = self.speechArbiter.selectBestAvailable() {
                self.emit(winner)
            }
        }
    }

    private func emit(_ candidate: SpeechRecognitionCandidate) {
        let signature = [
            String(describing: candidate.language),
            String(candidate.isFinal),
            String(candidate.startTime),
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
