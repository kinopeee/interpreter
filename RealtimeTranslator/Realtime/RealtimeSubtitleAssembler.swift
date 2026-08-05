import Foundation

struct RealtimeSubtitleUpdate: Equatable, Sendable {
    var sourceText: String
    var translatedText: String
    var isTranslationCurrent: Bool
    var shouldFinalize: Bool
    var segmentGeneration: Int
}

/// 原文authorityと日英2出力を時間整列し、自動lane選択する。
struct RealtimeSubtitleAssembler: Sendable {
    private struct BufferedDelta: Equatable, Sendable {
        let text: String
        let elapsedMs: Int?
        let eventID: String
    }

    // Realtime Translation can pause output deltas for 5 seconds or more while
    // continuing the same sentence. A short idle cutoff truncates the translation.
    private static let idleFinalizeInterval: TimeInterval = 8

    private var epoch = 0
    private var segmentGeneration = 0
    private var sourceText = ""
    private var englishText = ""
    private var japaneseText = ""
    private var selectedLane: RealtimeTranslationOutputLanguage?
    private var seenEventIDs = Set<String>()
    private var lastActivityAt = Date.distantPast
    private var finalizedCutoffElapsedMs: Int?
    private var awaitingSourceAfterFinalize = false

    mutating func reset(epoch: Int) {
        self.epoch = epoch
        segmentGeneration = 0
        clearSegmentBuffers(advancingGeneration: false)
        seenEventIDs.removeAll(keepingCapacity: true)
        finalizedCutoffElapsedMs = nil
        awaitingSourceAfterFinalize = false
    }

    mutating func beginNewEpoch(_ epoch: Int) {
        reset(epoch: epoch)
    }

    mutating func ingest(
        _ streamEvent: RealtimeTranslationStreamEvent,
        now: Date = Date()
    ) -> RealtimeSubtitleUpdate? {
        guard streamEvent.epoch == epoch else { return nil }

        switch streamEvent.event {
        case .inputTranscriptDelta(let delta, let eventID, let elapsedMs):
            guard streamEvent.target == .english else { return nil }
            return appendSource(delta, eventID: eventID, elapsedMs: elapsedMs, now: now)
        case .outputTranscriptDelta(let delta, let eventID, let elapsedMs):
            return appendTranslation(
                delta,
                target: streamEvent.target,
                eventID: eventID,
                elapsedMs: elapsedMs,
                now: now
            )
        default:
            return nil
        }
    }

    mutating func tick(now: Date = Date()) -> RealtimeSubtitleUpdate? {
        evaluateFinalize(now: now)
    }

    private mutating func appendSource(
        _ delta: String,
        eventID: String?,
        elapsedMs: Int?,
        now: Date
    ) -> RealtimeSubtitleUpdate? {
        guard !delta.isEmpty else { return nil }
        if let eventID, !seenEventIDs.insert(eventID).inserted {
            return nil
        }
        if let elapsedMs, let cutoff = finalizedCutoffElapsedMs, elapsedMs <= cutoff {
            return nil
        }

        if awaitingSourceAfterFinalize {
            awaitingSourceAfterFinalize = false
        } else if shouldStartNewSegmentForSourceUpdate() {
            clearSegmentBuffers(advancingGeneration: true)
        }

        sourceText += delta
        lastActivityAt = now
        resolveLaneIfNeeded()
        return snapshot(isTranslationCurrent: selectedLane != nil && !currentTranslation.isEmpty)
    }

    private mutating func appendTranslation(
        _ delta: String,
        target: RealtimeTranslationOutputLanguage,
        eventID: String?,
        elapsedMs: Int?,
        now: Date
    ) -> RealtimeSubtitleUpdate? {
        guard !delta.isEmpty else { return nil }
        // 確定後に届いた旧segmentの訳文で、保持中の完全ペアを上書きしない。
        // 次のsource deltaが来るまでtarget deltaは破棄する。
        guard !awaitingSourceAfterFinalize else { return nil }
        if let eventID, !seenEventIDs.insert(eventID).inserted {
            return nil
        }
        if let elapsedMs, let cutoff = finalizedCutoffElapsedMs, elapsedMs <= cutoff {
            return nil
        }

        switch target {
        case .english:
            englishText += delta
        case .japanese:
            japaneseText += delta
        }

        lastActivityAt = now

        if selectedLane == nil {
            // 一次信号: どちらのセッションが訳文を出したか。
            if englishText.isEmpty != japaneseText.isEmpty {
                selectedLane = englishText.isEmpty ? .japanese : .english
            } else {
                resolveLaneIfNeeded()
            }
        }

        // 非選択laneはbufferのみ。表示中の選択laneの現行フラグは維持する。
        return snapshot(
            isTranslationCurrent: selectedLane != nil
                && !sourceText.isEmpty
                && !currentTranslation.isEmpty
        )
    }

    private mutating func resolveLaneIfNeeded() {
        guard selectedLane == nil else { return }

        // 一次: 片側だけが出力していればそれを選ぶ。
        if !englishText.isEmpty && japaneseText.isEmpty {
            selectedLane = .english
            return
        }
        if !japaneseText.isEmpty && englishText.isEmpty {
            selectedLane = .japanese
            return
        }

        // 補助: 原文の文字種。
        switch SpokenLanguageDetector.detect(sourceText) {
        case .japanese:
            selectedLane = .english
        case .english:
            selectedLane = .japanese
        case .unknown:
            break
        }
    }

    private mutating func evaluateFinalize(now: Date) -> RealtimeSubtitleUpdate? {
        guard !sourceText.isEmpty, let selectedLane else { return nil }
        let translation = currentTranslation
        guard !translation.isEmpty else { return nil }

        let idleExpired = now.timeIntervalSince(lastActivityAt) >= Self.idleFinalizeInterval
        if idleExpired {
            return finalizeCurrent(elapsedHint: nil, now: now)
        }
        return nil
    }

    private mutating func finalizeCurrent(
        elapsedHint: Int?,
        now: Date
    ) -> RealtimeSubtitleUpdate {
        if let elapsedHint {
            finalizedCutoffElapsedMs = elapsedHint
        }
        let update = RealtimeSubtitleUpdate(
            sourceText: sourceText,
            translatedText: currentTranslation,
            isTranslationCurrent: true,
            shouldFinalize: true,
            segmentGeneration: segmentGeneration
        )
        // 次のsource開始まで表示内容はaggregator側で保持する。
        clearSegmentBuffers(advancingGeneration: true)
        awaitingSourceAfterFinalize = true
        lastActivityAt = now
        return update
    }

    private var currentTranslation: String {
        switch selectedLane {
        case .english:
            return englishText
        case .japanese:
            return japaneseText
        case nil:
            return ""
        }
    }

    private func snapshot(isTranslationCurrent: Bool) -> RealtimeSubtitleUpdate {
        let translation = selectedLane == nil ? "" : currentTranslation
        return RealtimeSubtitleUpdate(
            sourceText: sourceText,
            translatedText: translation,
            isTranslationCurrent: isTranslationCurrent && !translation.isEmpty,
            shouldFinalize: false,
            segmentGeneration: segmentGeneration
        )
    }

    private mutating func clearSegmentBuffers(advancingGeneration: Bool) {
        sourceText = ""
        englishText = ""
        japaneseText = ""
        selectedLane = nil
        if advancingGeneration {
            segmentGeneration += 1
        }
    }

    private func shouldStartNewSegmentForSourceUpdate() -> Bool {
        // 直前segment確定後、空のまま次の原文が来たら新segmentとして扱う。
        sourceText.isEmpty && selectedLane == nil && (!englishText.isEmpty || !japaneseText.isEmpty)
    }

}
