import XCTest
@testable import RealtimeTranslator

final class BilingualSpeechArbiterTests: XCTestCase {
    func testWaitsForBothLanguageCandidatesBeforeChoosing() {
        // Given: 言語が未確定の判定器
        var arbiter = BilingualSpeechArbiter()
        let japanese = candidate(language: .japanese, confidence: 0.8)

        // When: 日本語レーンだけが先に届く
        let selected = arbiter.submit(japanese)

        // Then: 早すぎる言語確定を行わない
        XCTAssertNil(selected)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertTrue(arbiter.hasPendingCandidates)
    }

    func testKeepsSelectedLanguageUntilFinalResult() {
        // Given: 日本語レーンの信頼度が高い同一区間の候補
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.45))
        let selected = arbiter.submit(candidate(language: .japanese, confidence: 0.9))

        // When: 選択後に英語レーンの更新が届く
        let ignored = arbiter.submit(candidate(language: .english, confidence: 0.99))

        // Then: 文中では日本語レーンを維持して表示の往復を防ぐ
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
        XCTAssertNil(ignored)
    }

    func testCanChooseOppositeLanguageAfterFinalResult() {
        // Given: 日本語レーンを選択済みの判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))

        // When: 日本語の確定結果後、次区間で英語候補を受け取る
        let finalized = arbiter.submit(
            candidate(language: .japanese, confidence: 0.92, isFinal: true)
        )
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.3, start: 2))
        let next = arbiter.submit(candidate(language: .english, confidence: 0.95, start: 2))

        // Then: ロックを解除して次の英語区間を選択できる
        XCTAssertTrue(finalized?.isFinal == true)
        XCTAssertEqual(next?.language, .english)
        XCTAssertEqual(arbiter.activeLanguage, .english)
    }

    func testIgnoresLateOppositeFinalForFinalizedRange() {
        // Given: 同一区間で日本語レーンを選択し、確定結果まで受信した判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))
        let finalized = arbiter.submit(
            candidate(language: .japanese, confidence: 0.92, isFinal: true)
        )

        // When: 同じ音声範囲の英語レーン確定結果が遅れて届く
        let lateOpposite = arbiter.submit(
            candidate(language: .english, confidence: 0.99, isFinal: true)
        )

        // Then: 同じ音声を別発話として再選択しない
        XCTAssertTrue(finalized?.isFinal == true)
        XCTAssertNil(lateOpposite)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertFalse(arbiter.hasPendingCandidates)
    }

    func testKeepsSameLanguageCandidatesInSeparateRangeBuckets() {
        // Given: 離れた2区間に日本語候補が先行している判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9, start: 0))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.8, start: 2))

        // When: 最初の区間に対応する英語候補が遅れて届く
        let selected = arbiter.submit(
            candidate(language: .english, confidence: 0.4, start: 0)
        )

        // Then: 後続の日本語候補に上書きされず最初の区間を比較できる
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.startTime, 0)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testDoesNotPairNearbyButNonOverlappingRanges() {
        // Given: 開始時刻は1秒以内だが重ならない短い2区間
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                language: .japanese,
                confidence: 0.9,
                start: 0,
                end: 0.2
            )
        )

        // When: 別区間の英語候補が届く
        let selected = arbiter.submit(
            candidate(
                language: .english,
                confidence: 0.95,
                start: 0.8,
                end: 1
            )
        )

        // Then: 異なる音声範囲を日英候補として比較しない
        XCTAssertNil(selected)
        XCTAssertNil(arbiter.activeLanguage)
    }

    func testQueuesNextRangeWhileCurrentRangeIsLocked() {
        // Given: 最初の区間で日本語レーンを選択済みの判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4, start: 0))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9, start: 0))

        // When: 次区間の日本語finalが先に届いた後、最初の区間を確定する
        let queued = arbiter.submit(
            candidate(language: .japanese, confidence: 0.95, isFinal: true, start: 2)
        )
        let currentFinal = arbiter.submit(
            candidate(language: .japanese, confidence: 0.92, isFinal: true, start: 0)
        )
        let next = arbiter.selectBestAvailable()

        // Then: 次区間は現在区間のfinalと混同せず、確定後に選択する
        XCTAssertNil(queued)
        XCTAssertEqual(currentFinal?.startTime, 0)
        XCTAssertEqual(next?.startTime, 2)
        XCTAssertTrue(next?.isFinal == true)
    }

    func testEmptyVolatileRetractsSelectedRangeWithoutUnlockingLanguage() {
        // Given: 日本語レーンの暫定結果を表示中の判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))

        // When: 同じ日本語レーンから空のvolatile結果が届く
        let retraction = arbiter.submit(
            candidate(
                text: "",
                language: .japanese,
                confidence: 0,
                isFinal: false
            )
        )

        // Then: 空文字をretractionとして返し、文中の言語固定は維持する
        XCTAssertEqual(retraction?.text, "")
        XCTAssertFalse(retraction?.isFinal == true)
        XCTAssertEqual(arbiter.activeLanguage, .japanese)
    }

    func testEmptyFinalUnlocksRangeAndAllowsOppositeLane() {
        // Given: 日本語レーンを選択し、同一区間の英語候補も保持する判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(candidate(language: .english, confidence: 0.4))
        _ = arbiter.submit(candidate(language: .japanese, confidence: 0.9))

        // When: 選択中の日本語レーンが空のfinalへ置き換わる
        let retraction = arbiter.submit(
            candidate(
                text: "",
                language: .japanese,
                confidence: 0,
                isFinal: true
            )
        )
        let replacement = arbiter.selectBestAvailable()

        // Then: 空finalを通知してロックを解除し、英語候補を再選択できる
        XCTAssertEqual(retraction?.text, "")
        XCTAssertTrue(retraction?.isFinal == true)
        XCTAssertEqual(replacement?.language, .english)
        XCTAssertEqual(arbiter.activeLanguage, .english)
    }

    func testDefersLatinOnlyVolatileCandidatesUntilJapaneseContextArrives() {
        // Given: 日英両レーンが同じLatin単語だけを暫定認識している判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(text: "Cursor", language: .english, confidence: 0.98)
        )

        // When: 日本語レーンのLatin単語候補と、その後の日本語文脈が届く
        let ambiguous = arbiter.submit(
            candidate(text: "Cursor", language: .japanese, confidence: 0.85)
        )
        let timeoutSelection = arbiter.selectBestAvailable()
        let contextual = arbiter.submit(
            candidate(text: "Cursorについて", language: .japanese, confidence: 0.8)
        )

        // Then: Latin単語だけでは固定せず、日本語文字を含む候補を選択する
        XCTAssertNil(ambiguous)
        XCTAssertNil(timeoutSelection)
        XCTAssertEqual(contextual?.language, .japanese)
        XCTAssertEqual(contextual?.text, "Cursorについて")
    }

    func testAllowsMultiwordEnglishVolatileCandidate() {
        // Given: 複数のLatin単語を含む英語のvolatile候補
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(text: "Open the file", language: .english, confidence: 0.8)
        )

        // When: 対向レーン待ちの期限後として最良候補を選ぶ
        let selected = arbiter.selectBestAvailable()

        // Then: 十分な英語証拠があるためvolatileでも英語レーンを選択する
        XCTAssertEqual(selected?.language, .english)
        XCTAssertFalse(selected?.isFinal == true)
        XCTAssertEqual(arbiter.activeLanguage, .english)
    }

    func testAllowsFinalLatinOnlyCandidate() {
        // Given: 言語を単語だけでは断定できないLatin固有名詞の候補
        var arbiter = BilingualSpeechArbiter()

        // When: 英語レーンからfinalとして届き、対向レーン待ちの期限を迎える
        let immediate = arbiter.submit(
            candidate(
                text: "Cursor",
                language: .english,
                confidence: 0.9,
                isFinal: true
            )
        )
        let selected = arbiter.selectBestAvailable()

        // Then: 単独finalでは即決せず、期限後には欠落させず英語として返す
        XCTAssertNil(immediate)
        XCTAssertEqual(selected?.language, .english)
        XCTAssertTrue(selected?.isFinal == true)
        XCTAssertNil(arbiter.activeLanguage)
    }

    func testComparesOppositeFinalThatArrivesBeforeSelectionDeadline() {
        // Given: 同一区間で信頼度の低い英語finalが先着した判定器
        var arbiter = BilingualSpeechArbiter()
        let early = arbiter.submit(
            candidate(
                text: "テストです",
                language: .english,
                confidence: 0.55,
                isFinal: true
            )
        )

        // When: 対向レーン待ちの間に高信頼度の日本語finalが届く
        let selected = arbiter.submit(
            candidate(
                text: "テストです",
                language: .japanese,
                confidence: 0.9,
                isFinal: true
            )
        )

        // Then: 先着順で誤固定せず、両候補を比較して日本語を選ぶ
        XCTAssertNil(early)
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertTrue(selected?.isFinal == true)
    }

    func testExpandsRangeBucketAsVolatileResultGrows() {
        // Given: 同じ日本語認識が短い区間から長い区間へ成長している判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "テ",
                language: .japanese,
                confidence: 0.7,
                start: 0,
                end: 0.2
            )
        )
        _ = arbiter.submit(
            candidate(
                text: "テストです",
                language: .japanese,
                confidence: 0.9,
                start: 0,
                end: 1
            )
        )

        // When: 成長後の後半区間と重なる英語候補が届く
        let selected = arbiter.submit(
            candidate(
                text: "test",
                language: .english,
                confidence: 0.5,
                start: 0.3,
                end: 1
            )
        )

        // Then: 別bucketに分離せず、同一区間の日英候補として比較する
        XCTAssertEqual(selected?.language, .japanese)
        XCTAssertEqual(selected?.text, "テストです")
        XCTAssertEqual(arbiter.pendingRangeCount, 1)
    }

    func testDiscardsUnselectedEmptyVolatileBucket() {
        // Given: 候補をまだ選択していない判定器
        var arbiter = BilingualSpeechArbiter()

        // When: 空のvolatile結果だけが届く
        let selected = arbiter.submit(
            candidate(
                text: "",
                language: .english,
                confidence: 0,
                start: 4,
                end: 4.2
            )
        )

        // Then: 表示せず、空bucketも録音中に蓄積しない
        XCTAssertNil(selected)
        XCTAssertEqual(arbiter.pendingRangeCount, 0)
        XCTAssertFalse(arbiter.hasPendingCandidates)
    }

    func testDiscardsUnselectedSingleLaneEmptyFinalBucket() {
        // Given: 候補をまだ選択していない判定器
        var arbiter = BilingualSpeechArbiter()

        // When: 一方のレーンから空finalだけが届く
        _ = arbiter.submit(
            candidate(
                text: "",
                language: .japanese,
                confidence: 0,
                isFinal: true,
                start: 6,
                end: 6.5
            )
        )

        // Then: 対向候補のない空rangeを録音終了まで保持しない
        XCTAssertEqual(arbiter.pendingRangeCount, 0)
        XCTAssertFalse(arbiter.hasPendingCandidates)
    }

    func testDiscardsActiveSingleLaneBucketAfterEmptyFinal() {
        // Given: 対向候補なしで期限後に日本語レーンを選択した判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(language: .japanese, confidence: 0.9)
        )
        _ = arbiter.selectBestAvailable()
        XCTAssertEqual(arbiter.activeLanguage, .japanese)

        // When: 選択中レーンが空finalへ置き換わる
        let retraction = arbiter.submit(
            candidate(
                text: "",
                language: .japanese,
                confidence: 0,
                isFinal: true
            )
        )

        // Then: retractionを通知し、markerだけのbucketを残さない
        XCTAssertEqual(retraction?.text, "")
        XCTAssertTrue(retraction?.isFinal == true)
        XCTAssertNil(arbiter.activeLanguage)
        XCTAssertEqual(arbiter.pendingRangeCount, 0)
    }

    func testSkipsUnselectableAmbiguousRangeForLaterClearSpeech() {
        // Given: 先頭に曖昧なLatin一語、後続に明確な英語文がある判定器
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "Cursor",
                language: .english,
                confidence: 0.95,
                start: 0
            )
        )
        _ = arbiter.submit(
            candidate(
                text: "Open the file",
                language: .english,
                confidence: 0.8,
                start: 2
            )
        )

        // When: 対向レーン待ちの期限後に選択する
        let selected = arbiter.selectBestAvailable()

        // Then: 選択不能な先頭rangeで後続字幕を塞がない
        XCTAssertEqual(selected?.text, "Open the file")
        XCTAssertEqual(selected?.startTime, 2)
    }

    func testFinalAmbiguousLatinCompetesByConfidence() {
        // Given: 英語一語finalと、同一区間の低信頼度な日本語final
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "Yes",
                language: .english,
                confidence: 0.95,
                isFinal: true
            )
        )

        // When: 日本語文字を含む対向finalが届く
        let selected = arbiter.submit(
            candidate(
                text: "イエス",
                language: .japanese,
                confidence: 0.5,
                isFinal: true
            )
        )

        // Then: finalのLatin一語を除外せず、補正後scoreで英語を選ぶ
        XCTAssertEqual(selected?.language, .english)
        XCTAssertEqual(selected?.text, "Yes")
    }

    func testLosingLaneRangeDoesNotFinalizeLaterSpeech() {
        // Given: 勝者の日本語rangeより敗者の英語rangeが大幅に長い候補
        var arbiter = BilingualSpeechArbiter()
        _ = arbiter.submit(
            candidate(
                text: "incorrect long range",
                language: .english,
                confidence: 0.3,
                start: 0,
                end: 10
            )
        )
        let finalized = arbiter.submit(
            candidate(
                text: "確定",
                language: .japanese,
                confidence: 0.95,
                isFinal: true,
                start: 0,
                end: 1
            )
        )

        // When: 敗者range内だが勝者range後の別発話が届く
        _ = arbiter.submit(
            candidate(
                text: "次",
                language: .japanese,
                confidence: 0.8,
                start: 2,
                end: 3
            )
        )
        let next = arbiter.submit(
            candidate(
                text: "next",
                language: .english,
                confidence: 0.4,
                start: 2,
                end: 3
            )
        )

        // Then: 勝者rangeだけを確定済みにし、後続発話を破棄しない
        XCTAssertEqual(finalized?.language, .japanese)
        XCTAssertEqual(next?.language, .japanese)
        XCTAssertEqual(next?.startTime, 2)
    }

    private func candidate(
        text: String? = nil,
        language: SpokenLanguage,
        confidence: Double,
        isFinal: Bool = false,
        start: Double = 0,
        end: Double? = nil
    ) -> SpeechRecognitionCandidate {
        SpeechRecognitionCandidate(
            text: text ?? (language == .japanese ? "テストです" : "This is a test"),
            language: language,
            confidence: confidence,
            isFinal: isFinal,
            startTime: start,
            endTime: end ?? start + 1
        )
    }
}
