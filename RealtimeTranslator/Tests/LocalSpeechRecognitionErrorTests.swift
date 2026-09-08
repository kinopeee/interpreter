import XCTest
@testable import RealtimeTranslator

final class LocalSpeechRecognitionErrorTests: XCTestCase {
    func testPermissionErrorsUseStableJapaneseMessages() {
        // Given: マイクと音声認識の拒否
        // When: ユーザー向け説明を取得する
        // Then: 権限画面へ誘導できる固定文を返す
        XCTAssertEqual(
            LocalSpeechRecognitionError.microphoneDenied.errorDescription,
            "マイクを利用できません"
        )
        XCTAssertEqual(
            LocalSpeechRecognitionError.speechRecognitionDenied.errorDescription,
            "音声認識を利用できません"
        )
    }

    func testAvailabilityErrorsDoNotCollapseToGenericFailure() {
        // Given: 認識器・音声形式・変換・バッファの準備失敗
        // When: ユーザー向け説明を取得する
        // Then: 原因ごとに異なる案内を返す
        XCTAssertEqual(
            LocalSpeechRecognitionError.speechTranscriberUnavailable.errorDescription,
            "このMacではローカル音声認識を利用できません"
        )
        XCTAssertEqual(
            LocalSpeechRecognitionError.audioFormatUnavailable.errorDescription,
            "音声認識用の音声形式を取得できません"
        )
        XCTAssertEqual(
            LocalSpeechRecognitionError.audioConverterUnavailable.errorDescription,
            "音声認識用の音声変換を開始できません"
        )
        XCTAssertEqual(
            LocalSpeechRecognitionError.audioBufferPoolUnavailable.errorDescription,
            "音声認識用の音声バッファを準備できません"
        )
    }

    func testAssociatedValuesAppearInErrorDescription() {
        // Given: 非対応ロケールとモデル導入失敗
        let unsupported = LocalSpeechRecognitionError.localeUnsupported("fr_FR")
        let installation = LocalSpeechRecognitionError.modelInstallationFailed(
            "download timed out"
        )

        // When: ユーザー向け説明を取得する
        // Then: 関連値を埋め込み、原文メッセージを捨てない
        XCTAssertEqual(
            unsupported.errorDescription,
            "ローカル音声認識が fr_FR に対応していません"
        )
        XCTAssertEqual(
            installation.errorDescription,
            "音声認識モデルを準備できません: download timed out"
        )
    }

    func testTranslationSessionUnavailableMessageIsStable() {
        // Given: Apple Translationセッションが使えない状態
        // When: ユーザー向け説明を取得する
        // Then: キュー満杯とは別の案内を返す
        XCTAssertEqual(
            LocalTranslationError.sessionUnavailable.errorDescription,
            "ローカル翻訳モデルを準備できません"
        )
        XCTAssertNotEqual(
            LocalTranslationError.sessionUnavailable,
            LocalTranslationError.queueFull
        )
    }
}
