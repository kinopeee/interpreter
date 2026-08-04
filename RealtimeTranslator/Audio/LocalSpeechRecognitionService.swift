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
protocol LocalSpeechRecognitionServiceDelegate: AnyObject {
    func localSpeechRecognitionService(
        _ service: LocalSpeechRecognitionService,
        didUpdate text: String,
        language: SpokenLanguage,
        isFinal: Bool
    )
    func localSpeechRecognitionService(
        _ service: LocalSpeechRecognitionService,
        didUpdateStatus message: String
    )
    func localSpeechRecognitionService(
        _ service: LocalSpeechRecognitionService,
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
final class LocalSpeechRecognitionService {
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
    private(set) var isRunning = false

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        guard await requestPermission() else {
            throw LocalSpeechRecognitionError.microphoneDenied
        }
        guard await SpeechAuthorization.request() else {
            throw LocalSpeechRecognitionError.speechRecognitionDenied
        }
        guard SpeechTranscriber.isAvailable else {
            throw LocalSpeechRecognitionError.speechTranscriberUnavailable
        }

        delegate?.localSpeechRecognitionService(self, didUpdateStatus: "日英音声認識モデルを確認中…")

        let japaneseLocale = try await supportedLocale(identifier: "ja-JP")
        let englishLocale = try await supportedLocale(identifier: "en-US")
        let japaneseTranscriber = makeTranscriber(locale: japaneseLocale)
        let englishTranscriber = makeTranscriber(locale: englishLocale)
        let modules: [any SpeechModule] = [japaneseTranscriber, englishTranscriber]

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                delegate?.localSpeechRecognitionService(
                    self,
                    didUpdateStatus: "日英音声認識モデルをダウンロード中…"
                )
                try await request.downloadAndInstall()
            }
        } catch {
            throw LocalSpeechRecognitionError.modelInstallationFailed(error.localizedDescription)
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
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
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let (captureStream, captureContinuation) = AsyncStream<CapturedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )

        self.analyzer = analyzer
        self.japaneseTranscriber = japaneseTranscriber
        self.englishTranscriber = englishTranscriber
        self.captureContinuation = captureContinuation
        inputContinuation = continuation
        audioConverter = converter
        speechArbiter.reset()
        languageSelectionTask?.cancel()
        languageSelectionTask = nil
        lastEmittedSignature = nil

        startResultTasks(
            japaneseTranscriber: japaneseTranscriber,
            englishTranscriber: englishTranscriber
        )
        try await analyzer.start(inputSequence: inputStream)

        feederTask = Task.detached(priority: .userInitiated) { [weak self] in
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
                await self?.reportAudioFeederFailure(error)
            }
        }

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

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        delegate?.localSpeechRecognitionService(self, didUpdateStatus: "録音中… 話してください")
    }

    func stop() async {
        guard isRunning || analyzer != nil else { return }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        captureContinuation?.finish()
        captureContinuation = nil
        await feederTask?.value
        feederTask = nil
        inputContinuation = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        for task in resultTasks {
            task.cancel()
        }
        resultTasks.removeAll()
        languageSelectionTask?.cancel()
        languageSelectionTask = nil
        analyzer = nil
        japaneseTranscriber = nil
        englishTranscriber = nil
        audioConverter = nil
        speechArbiter.reset()
    }

    private func reportAudioFeederFailure(_ error: Error) {
        delegate?.localSpeechRecognitionService(self, didFail: error)
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

    private func startResultTasks(
        japaneseTranscriber: SpeechTranscriber,
        englishTranscriber: SpeechTranscriber
    ) {
        resultTasks = [
            Task { [weak self] in
                do {
                    for try await result in japaneseTranscriber.results {
                        self?.handle(result: result, language: .japanese)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.delegate?.localSpeechRecognitionService(self, didFail: error)
                }
            },
            Task { [weak self] in
                do {
                    for try await result in englishTranscriber.results {
                        self?.handle(result: result, language: .english)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.delegate?.localSpeechRecognitionService(self, didFail: error)
                }
            },
        ]
    }

    private func handle(result: SpeechTranscriber.Result, language: SpokenLanguage) {
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
            self,
            didUpdate: candidate.text,
            language: candidate.language,
            isFinal: candidate.isFinal
        )
    }
}
