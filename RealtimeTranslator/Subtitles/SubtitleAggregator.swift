import Foundation

struct SubtitleAggregatorConfig: Sendable {
    var idleFinalizeInterval: TimeInterval = 1.0
    var maxJapaneseCharacters = 60
    var maxEnglishCharacters = 120
    var previousHoldInterval: TimeInterval = 5.0
    var fadeDuration: TimeInterval = 0.3
}

final class SubtitleAggregator: @unchecked Sendable {
    private let config: SubtitleAggregatorConfig
    private let lock = NSLock()

    private var current = LiveSubtitle.empty
    private var previous: LiveSubtitle?
    private var previousFinalizedAt: Date?
    private var statusBanner: String?
    private var previousOpacity: Double = 1

    init(config: SubtitleAggregatorConfig = SubtitleAggregatorConfig()) {
        self.config = config
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        current = .empty
        previous = nil
        previousFinalizedAt = nil
        statusBanner = nil
        previousOpacity = 1
    }

    func setStatusBanner(_ message: String?) {
        lock.lock()
        defer { lock.unlock() }
        statusBanner = message
    }

    @discardableResult
    func replaceCurrent(
        sourceText: String,
        translatedText: String,
        isTranslationCurrent: Bool = true,
        canFinalize: Bool = true,
        now: Date = Date()
    ) -> SubtitleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        current = LiveSubtitle(
            sourceText: sourceText,
            translatedText: translatedText,
            lastUpdatedAt: now,
            state: .live,
            isTranslationCurrent: isTranslationCurrent,
            canFinalize: canFinalize
        )
        return snapshotLocked(now: now)
    }

    @discardableResult
    func appendSource(_ delta: String, now: Date = Date()) -> SubtitleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !delta.isEmpty else { return snapshotLocked(now: now) }
        current.sourceText += delta
        current.isTranslationCurrent = false
        current.canFinalize = false
        current.lastUpdatedAt = now
        current.state = .live
        finalizeIfNeededLocked(now: now)
        return snapshotLocked(now: now)
    }

    @discardableResult
    func appendTranslation(_ delta: String, now: Date = Date()) -> SubtitleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !delta.isEmpty else { return snapshotLocked(now: now) }
        current.translatedText += delta
        current.isTranslationCurrent = true
        current.canFinalize = true
        current.lastUpdatedAt = now
        current.state = .live
        finalizeIfNeededLocked(now: now)
        return snapshotLocked(now: now)
    }

    @discardableResult
    func tick(now: Date = Date()) -> SubtitleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        finalizeIfNeededLocked(now: now)
        updatePreviousOpacityLocked(now: now)
        return snapshotLocked(now: now)
    }

    @discardableResult
    func forceFinalize(now: Date = Date()) -> SubtitleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if hasCompletePair(current) {
            promoteCurrentLocked(now: now)
        } else {
            clearCurrentLocked(now: now)
        }
        updatePreviousOpacityLocked(now: now)
        return snapshotLocked(now: now)
    }

    @discardableResult
    func finalizePair(
        sourceText: String,
        translatedText: String,
        clearCurrent: Bool,
        now: Date = Date()
    ) -> SubtitleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let finalized = LiveSubtitle(
            sourceText: sourceText,
            translatedText: translatedText,
            lastUpdatedAt: now,
            state: .finalized,
            isTranslationCurrent: true,
            canFinalize: true
        )
        guard hasCompletePair(finalized) else {
            return snapshotLocked(now: now)
        }

        previous = finalized
        previousFinalizedAt = now
        previousOpacity = 1
        if clearCurrent {
            clearCurrentLocked(now: now)
        }
        updatePreviousOpacityLocked(now: now)
        return snapshotLocked(now: now)
    }

    func snapshot(now: Date = Date()) -> SubtitleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        updatePreviousOpacityLocked(now: now)
        return snapshotLocked(now: now)
    }

    private func finalizeIfNeededLocked(now: Date) {
        guard !current.isEmpty else { return }

        guard hasCompletePair(current) else { return }

        let idleExpired = now.timeIntervalSince(current.lastUpdatedAt) >= config.idleFinalizeInterval
        // Wait for target punctuation. Source punctuation often arrives before translation
        // and finalizing there would split the source and translation into separate blocks.
        let punctuation = endsWithTerminalPunctuation(current.translatedText)
        let tooLong = exceedsMaxLength(current.sourceText, japanesePreferred: true)
            || exceedsMaxLength(current.translatedText, japanesePreferred: false)

        if punctuation || idleExpired || tooLong {
            promoteCurrentLocked(now: now)
        }
    }

    private func promoteCurrentLocked(now: Date) {
        guard hasCompletePair(current) else { return }
        var finalized = current
        finalized.state = .finalized
        finalized.lastUpdatedAt = now
        previous = finalized
        previousFinalizedAt = now
        previousOpacity = 1
        clearCurrentLocked(now: now)
    }

    private func clearCurrentLocked(now: Date) {
        current = LiveSubtitle(
            sourceText: "",
            translatedText: "",
            lastUpdatedAt: now,
            state: .live,
            isTranslationCurrent: false,
            canFinalize: false
        )
    }

    private func hasCompletePair(_ subtitle: LiveSubtitle) -> Bool {
        !subtitle.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !subtitle.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && subtitle.isTranslationCurrent
            && subtitle.canFinalize
    }

    private func updatePreviousOpacityLocked(now: Date) {
        guard let previousFinalizedAt else {
            previousOpacity = 1
            return
        }
        let elapsed = now.timeIntervalSince(previousFinalizedAt)
        if elapsed < config.previousHoldInterval {
            previousOpacity = 1
            if var previous {
                previous.state = .finalized
                self.previous = previous
            }
            return
        }

        let fadeElapsed = elapsed - config.previousHoldInterval
        if fadeElapsed >= config.fadeDuration {
            previous = nil
            self.previousFinalizedAt = nil
            previousOpacity = 0
            return
        }

        previousOpacity = max(0, 1 - (fadeElapsed / config.fadeDuration))
        if var previous {
            previous.state = .fading
            self.previous = previous
        }
    }

    private func snapshotLocked(now: Date) -> SubtitleSnapshot {
        _ = now
        return SubtitleSnapshot(
            current: current,
            previous: previous,
            statusBanner: statusBanner,
            previousOpacity: previousOpacity
        )
    }

    private func endsWithTerminalPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return "。．.!？?！".contains(last)
    }

    private func exceedsMaxLength(_ text: String, japanesePreferred: Bool) -> Bool {
        let limit = japanesePreferred ? config.maxJapaneseCharacters : config.maxEnglishCharacters
        // Prefer Japanese limit when text contains CJK; otherwise English limit.
        let hasCJK = text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
        let effective = hasCJK ? config.maxJapaneseCharacters : (japanesePreferred ? limit : config.maxEnglishCharacters)
        return text.count > effective
    }
}
