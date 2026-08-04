import Foundation

enum SpokenLanguage: Equatable, Hashable, Sendable {
    case japanese
    case english
    case unknown

    var translationTarget: TranslationTarget? {
        switch self {
        case .japanese:
            return .english
        case .english:
            return .japanese
        case .unknown:
            return nil
        }
    }
}

enum TranslationTarget: String, Equatable, Sendable {
    case english = "en"
    case japanese = "ja"
}

enum SpokenLanguageEvidence: Equatable, Sendable {
    case japanese
    case english
    case ambiguousLatin
    case none
}

enum SpokenLanguageDetector {
    static func detect(_ text: String) -> SpokenLanguage {
        switch evidence(in: text) {
        case .japanese:
            return .japanese
        case .english:
            return .english
        case .ambiguousLatin, .none:
            return .unknown
        }
    }

    static func evidence(in text: String) -> SpokenLanguageEvidence {
        var hasJapanese = false
        var latinWordCount = 0
        var isInsideLatinWord = false

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                hasJapanese = true
                isInsideLatinWord = false
            case 0x0041...0x005A, 0x0061...0x007A:
                if !isInsideLatinWord {
                    latinWordCount += 1
                    isInsideLatinWord = true
                }
            default:
                isInsideLatinWord = false
            }
        }

        if hasJapanese {
            return .japanese
        }
        switch latinWordCount {
        case 0:
            return .none
        case 1:
            return .ambiguousLatin
        default:
            return .english
        }
    }
}

struct SpeechRecognitionCandidate: Equatable, Sendable {
    let text: String
    let language: SpokenLanguage
    let confidence: Double
    let isFinal: Bool
    let startTime: Double
    let endTime: Double

    var score: Double {
        let scriptBonus: Double
        switch SpokenLanguageDetector.evidence(in: text) {
        case .japanese:
            scriptBonus = language == .japanese ? 0.1 : -0.15
        case .english:
            scriptBonus = language == .english ? 0.1 : -0.15
        case .ambiguousLatin, .none:
            scriptBonus = 0
        }
        return confidence + scriptBonus
    }

    var isAmbiguousLatinOnly: Bool {
        SpokenLanguageDetector.evidence(in: text) == .ambiguousLatin
    }
}

struct BilingualSpeechArbiter: Sendable {
    private struct SpeechRange: Sendable {
        var startTime: Double
        var endTime: Double

        init(_ candidate: SpeechRecognitionCandidate) {
            startTime = candidate.startTime
            endTime = candidate.endTime
        }

        func substantiallyOverlaps(_ candidate: SpeechRecognitionCandidate) -> Bool {
            substantiallyOverlaps(
                startTime: candidate.startTime,
                endTime: candidate.endTime
            )
        }

        func substantiallyOverlaps(_ other: SpeechRange) -> Bool {
            substantiallyOverlaps(
                startTime: other.startTime,
                endTime: other.endTime
            )
        }

        func distance(to candidate: SpeechRecognitionCandidate) -> Double {
            abs(startTime - candidate.startTime) + abs(endTime - candidate.endTime)
        }

        mutating func formUnion(_ candidate: SpeechRecognitionCandidate) {
            startTime = min(startTime, candidate.startTime)
            endTime = max(endTime, candidate.endTime)
        }

        mutating func formUnion(_ other: SpeechRange) {
            startTime = min(startTime, other.startTime)
            endTime = max(endTime, other.endTime)
        }

        private func substantiallyOverlaps(
            startTime otherStartTime: Double,
            endTime otherEndTime: Double
        ) -> Bool {
            let intersectionStart = max(startTime, otherStartTime)
            let intersectionEnd = min(endTime, otherEndTime)
            let intersection = max(0, intersectionEnd - intersectionStart)
            let finalizedDuration = max(0.001, endTime - startTime)
            let candidateDuration = max(0.001, otherEndTime - otherStartTime)
            let shorterDuration = min(finalizedDuration, candidateDuration)
            return intersection / shorterDuration >= 0.5
                || abs(startTime - otherStartTime) < 0.1
        }
    }

    private struct RangeBucket: Sendable {
        let id: Int
        var range: SpeechRange
        var candidates: [SpokenLanguage: SpeechRecognitionCandidate] = [:]
        var finalizedEmptyLanguages: Set<SpokenLanguage> = []

        func matches(_ candidate: SpeechRecognitionCandidate) -> Bool {
            range.substantiallyOverlaps(candidate)
        }
    }

    private(set) var activeLanguage: SpokenLanguage?
    private var activeBucketID: Int?
    private var buckets: [RangeBucket] = []
    private var finalizedRanges: [SpeechRange] = []
    private var nextBucketID = 0

    var hasPendingCandidates: Bool {
        buckets.contains {
            !$0.candidates.isEmpty || !$0.finalizedEmptyLanguages.isEmpty
        }
    }

    var pendingRangeCount: Int {
        buckets.count
    }

    mutating func reset() {
        activeLanguage = nil
        activeBucketID = nil
        buckets.removeAll(keepingCapacity: true)
        finalizedRanges.removeAll(keepingCapacity: true)
        nextBucketID = 0
    }

    mutating func submit(
        _ candidate: SpeechRecognitionCandidate
    ) -> SpeechRecognitionCandidate? {
        guard !finalizedRanges.contains(where: { $0.substantiallyOverlaps(candidate) }) else {
            return nil
        }

        let bucketID = updateBucket(with: candidate)

        if let activeBucketID, let activeLanguage {
            guard bucketID == activeBucketID, candidate.language == activeLanguage else {
                return nil
            }

            if candidate.text.isEmpty {
                if candidate.isFinal {
                    self.activeBucketID = nil
                    self.activeLanguage = nil
                    removeBucketIfAllLanesFinalizedEmpty(bucketID)
                    removeBucketIfEmptyAndInactive(bucketID)
                }
                return candidate
            }

            if candidate.isFinal {
                completeRange(candidate, bucketID: bucketID)
            }
            return candidate
        }

        guard !candidate.text.isEmpty else {
            removeBucketIfAllLanesFinalizedEmpty(bucketID)
            removeBucketIfEmptyAndInactive(bucketID)
            return nil
        }

        guard let bucket = bucket(withID: bucketID),
              isReadyForImmediateSelection(bucket, submitted: candidate)
        else {
            return nil
        }
        return selectAndLock(bucketID: bucketID)
    }

    mutating func selectBestAvailable() -> SpeechRecognitionCandidate? {
        guard activeLanguage == nil else { return nil }
        let orderedBuckets = buckets
            .filter({ !$0.candidates.isEmpty })
            .sorted(by: { $0.range.startTime < $1.range.startTime })
        for bucket in orderedBuckets {
            if let selected = selectAndLock(bucketID: bucket.id) {
                return selected
            }
        }
        return nil
    }

    private mutating func updateBucket(
        with candidate: SpeechRecognitionCandidate
    ) -> Int {
        let bucketIndex: Int
        if let activeBucketID,
           let activeIndex = buckets.firstIndex(where: {
               $0.id == activeBucketID && $0.matches(candidate)
           })
        {
            bucketIndex = activeIndex
        } else if let matchingIndex = buckets.indices
            .filter({ buckets[$0].matches(candidate) })
            .min(by: {
                buckets[$0].range.distance(to: candidate)
                    < buckets[$1].range.distance(to: candidate)
            })
        {
            bucketIndex = matchingIndex
        } else {
            let bucket = RangeBucket(
                id: nextBucketID,
                range: SpeechRange(candidate)
            )
            nextBucketID += 1
            buckets.append(bucket)
            bucketIndex = buckets.index(before: buckets.endIndex)
        }

        if candidate.text.isEmpty {
            buckets[bucketIndex].candidates.removeValue(forKey: candidate.language)
            if candidate.isFinal {
                buckets[bucketIndex].finalizedEmptyLanguages.insert(candidate.language)
            } else {
                buckets[bucketIndex].finalizedEmptyLanguages.remove(candidate.language)
            }
        } else {
            buckets[bucketIndex].candidates[candidate.language] = candidate
            buckets[bucketIndex].finalizedEmptyLanguages.remove(candidate.language)
        }
        buckets[bucketIndex].range.formUnion(candidate)
        return mergeOverlappingBuckets(containing: buckets[bucketIndex].id)
    }

    private func bucket(withID id: Int) -> RangeBucket? {
        buckets.first(where: { $0.id == id })
    }

    private func isReadyForImmediateSelection(
        _ bucket: RangeBucket,
        submitted candidate: SpeechRecognitionCandidate
    ) -> Bool {
        bucket.candidates.count >= 2
            || bucket.finalizedEmptyLanguages.contains(opposite(of: candidate.language))
    }

    private mutating func selectAndLock(
        bucketID: Int
    ) -> SpeechRecognitionCandidate? {
        guard let bucket = bucket(withID: bucketID) else { return nil }
        let candidates = Array(bucket.candidates.values)
        guard !candidates.isEmpty else { return nil }
        guard !candidates.allSatisfy(\.isAmbiguousLatinOnly)
                || candidates.contains(where: \.isFinal)
        else {
            return nil
        }

        let candidatesWithLanguageEvidence = candidates.filter {
            switch SpokenLanguageDetector.evidence(in: $0.text) {
            case .japanese, .english:
                return true
            case .ambiguousLatin:
                return $0.isFinal
            case .none:
                return false
            }
        }
        let selectionPool = candidatesWithLanguageEvidence.isEmpty
            ? candidates
            : candidatesWithLanguageEvidence
        guard let winner = selectionPool.max(by: { $0.score < $1.score }) else {
            return nil
        }

        activeBucketID = bucketID
        activeLanguage = winner.language
        if winner.isFinal {
            completeRange(winner, bucketID: bucketID)
        }
        return winner
    }

    private mutating func completeRange(
        _ candidate: SpeechRecognitionCandidate,
        bucketID: Int
    ) {
        let completedRange = SpeechRange(candidate)
        finalizedRanges.append(completedRange)
        buckets.removeAll(where: {
            $0.id == bucketID || $0.range.substantiallyOverlaps(completedRange)
        })
        activeBucketID = nil
        activeLanguage = nil
    }

    private mutating func mergeOverlappingBuckets(containing bucketID: Int) -> Int {
        guard let seedBucket = bucket(withID: bucketID) else { return bucketID }
        var mergedRange = seedBucket.range
        var mergedIDs: Set<Int> = [bucketID]

        var didMerge = true
        while didMerge {
            didMerge = false
            for bucket in buckets where !mergedIDs.contains(bucket.id) {
                guard mergedRange.substantiallyOverlaps(bucket.range) else { continue }
                mergedIDs.insert(bucket.id)
                mergedRange.formUnion(bucket.range)
                didMerge = true
            }
        }
        guard mergedIDs.count > 1 else { return bucketID }

        let survivorID: Int
        if let activeBucketID, mergedIDs.contains(activeBucketID) {
            survivorID = activeBucketID
        } else {
            survivorID = bucketID
        }

        var candidates: [SpokenLanguage: SpeechRecognitionCandidate] = [:]
        var finalizedEmptyLanguages: Set<SpokenLanguage> = []
        let insertionIndex = buckets.indices
            .filter { mergedIDs.contains(buckets[$0].id) }
            .min() ?? buckets.endIndex
        for bucket in buckets where mergedIDs.contains(bucket.id) {
            finalizedEmptyLanguages.formUnion(bucket.finalizedEmptyLanguages)
            for (language, candidate) in bucket.candidates {
                if let existing = candidates[language] {
                    candidates[language] = preferred(existing, candidate)
                } else {
                    candidates[language] = candidate
                }
            }
        }
        finalizedEmptyLanguages.subtract(candidates.keys)

        buckets.removeAll(where: { mergedIDs.contains($0.id) })
        let mergedBucket = RangeBucket(
            id: survivorID,
            range: mergedRange,
            candidates: candidates,
            finalizedEmptyLanguages: finalizedEmptyLanguages
        )
        buckets.insert(mergedBucket, at: min(insertionIndex, buckets.endIndex))
        return survivorID
    }

    private func preferred(
        _ first: SpeechRecognitionCandidate,
        _ second: SpeechRecognitionCandidate
    ) -> SpeechRecognitionCandidate {
        if first.isFinal != second.isFinal {
            return second.isFinal ? second : first
        }
        if first.endTime != second.endTime {
            return second.endTime > first.endTime ? second : first
        }
        return second
    }

    private mutating func removeBucketIfAllLanesFinalizedEmpty(_ bucketID: Int) {
        guard let bucket = bucket(withID: bucketID),
              bucket.finalizedEmptyLanguages.contains(.japanese),
              bucket.finalizedEmptyLanguages.contains(.english)
        else {
            return
        }
        finalizedRanges.append(bucket.range)
        buckets.removeAll(where: { $0.id == bucketID })
    }

    private mutating func removeBucketIfEmptyAndInactive(_ bucketID: Int) {
        guard activeBucketID != bucketID,
              let bucket = bucket(withID: bucketID),
              bucket.candidates.isEmpty
        else {
            return
        }
        buckets.removeAll(where: { $0.id == bucketID })
    }

    private func opposite(of language: SpokenLanguage) -> SpokenLanguage {
        switch language {
        case .japanese:
            return .english
        case .english:
            return .japanese
        case .unknown:
            return .unknown
        }
    }
}
