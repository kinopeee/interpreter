import Foundation

/// 日英いずれかの認識レーンが出力した1候補。
struct SpeechRecognitionCandidate: Equatable, Sendable {
    /// 文字種がレーンの言語と一致したときのスコア加点。
    /// 不一致ペナルティ(-0.15)を加点(0.1)より大きくし、
    /// 「日本語文字を含むのに英語レーン」のような明確な誤認識を確実に負かす。
    private static let matchingScriptBonus = 0.1
    private static let mismatchedScriptPenalty = -0.15

    let text: String
    let language: SpokenLanguage
    let confidence: Double
    let isFinal: Bool
    let startTime: Double
    let endTime: Double

    /// レーン選択に使う総合スコア。認識信頼度に文字種の一致度を加味する。
    var score: Double {
        let scriptBonus: Double
        switch SpokenLanguageDetector.evidence(in: text) {
        case .japanese:
            scriptBonus = language == .japanese
                ? Self.matchingScriptBonus : Self.mismatchedScriptPenalty
        case .english:
            scriptBonus = language == .english
                ? Self.matchingScriptBonus : Self.mismatchedScriptPenalty
        case .ambiguousLatin, .none:
            scriptBonus = 0
        }
        return confidence + scriptBonus
    }

    var isAmbiguousLatinOnly: Bool {
        SpokenLanguageDetector.evidence(in: text) == .ambiguousLatin
    }
}

/// 日英2レーンの認識結果から発話区間ごとに勝者レーンを1つ選び、
/// 確定結果が出るまでそのレーンに固定する(表示言語の往復を防ぐ)。
///
/// - 発話区間は`RangeBucket`として時間範囲で束ね、重なった区間はマージする。
/// - レーン固定中(`activeLanguage != nil`)は他レーンの候補を破棄する。
/// - 確定済み区間(`finalizedRanges`)と重なる遅延候補は二重表示を防ぐため破棄する。
struct BilingualSpeechArbiter: Sendable {
    private struct SpeechRange: Sendable {
        /// 短い方の区間の50%以上が重なっていれば同一発話とみなす。
        private static let overlapRatioThreshold = 0.5
        /// 開始時刻が0.1秒未満しか離れていなければ、重なり率に関わらず同一発話とみなす。
        /// 2レーンが同じ発話を検出しても終了時刻は言語モデルごとにずれるため、開始側で救う。
        private static let nearStartToleranceSeconds = 0.1

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
            return intersection / shorterDuration >= Self.overlapRatioThreshold
                || abs(startTime - otherStartTime) < Self.nearStartToleranceSeconds
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

    /// 候補を受け付け、表示してよい候補を返す。破棄した場合は`nil`。
    mutating func submit(
        _ candidate: SpeechRecognitionCandidate
    ) -> SpeechRecognitionCandidate? {
        guard !finalizedRanges.contains(where: { $0.substantiallyOverlaps(candidate) }) else {
            return nil
        }

        let bucketID = updateBucket(with: candidate)

        if let activeBucketID, let activeLanguage {
            return submitToLockedLane(
                candidate,
                bucketID: bucketID,
                activeBucketID: activeBucketID,
                activeLanguage: activeLanguage
            )
        }
        return trySelectNewLane(candidate, bucketID: bucketID)
    }

    /// レーン固定中: 固定レーンと同じバケット・同じ言語の候補だけを通す。
    private mutating func submitToLockedLane(
        _ candidate: SpeechRecognitionCandidate,
        bucketID: Int,
        activeBucketID: Int,
        activeLanguage: SpokenLanguage
    ) -> SpeechRecognitionCandidate? {
        guard bucketID == activeBucketID, candidate.language == activeLanguage else {
            return nil
        }

        if candidate.text.isEmpty {
            // 空文字の確定は「発話の取り消し」。レーン固定を解除して次の発話に備える。
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

    /// レーン未固定: 両レーンの候補が出揃った時点で勝者を選び、レーンを固定する。
    private mutating func trySelectNewLane(
        _ candidate: SpeechRecognitionCandidate,
        bucketID: Int
    ) -> SpeechRecognitionCandidate? {
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
            || bucket.finalizedEmptyLanguages.contains(candidate.language.counterpart)
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

    /// 指定バケットと(推移的に)重なるバケット群を1つに統合し、生存バケットのIDを返す。
    private mutating func mergeOverlappingBuckets(containing bucketID: Int) -> Int {
        guard let seedBucket = bucket(withID: bucketID) else { return bucketID }

        // フェーズ1: 重なりの推移閉包を計算し、統合対象のID集合と統合後の範囲を求める。
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

        // フェーズ2: 生存バケットを決める。固定中レーンのバケットIDを最優先で残し、
        // レーン固定(activeBucketID)が無効なIDを指さないようにする。
        let survivorID: Int
        if let activeBucketID, mergedIDs.contains(activeBucketID) {
            survivorID = activeBucketID
        } else {
            survivorID = bucketID
        }

        // フェーズ3: 候補と確定空レーン情報をマージし、元の位置(最小インデックス)へ差し戻す。
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
}
