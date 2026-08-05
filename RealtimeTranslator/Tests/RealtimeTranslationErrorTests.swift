import XCTest
@testable import RealtimeTranslator

final class RealtimeTranslationErrorTests: XCTestCase {
    func testRecoverableFailureHidesInternalDetailFromUserMessage() {
        // Given: 内部詳細に秘密情報らしき文字列を含むrecoverable failure
        let error = RealtimeTranslationError.recoverableTransportFailure(
            "Authorization Bearer sk-secret send timeout"
        )

        // When: ユーザー向け文言とrecoverable判定を確認する
        let description = error.localizedDescription

        // Then: 再接続対象だが、内部詳細や秘密情報は表に出さない
        XCTAssertTrue(error.isRecoverable)
        XCTAssertEqual(description, "翻訳サーバーとの接続が切れました")
        XCTAssertFalse(description.contains("sk-"))
        XCTAssertFalse(description.contains("Authorization"))
        XCTAssertFalse(description.contains("Bearer"))
    }

    func testAuthenticationFailureIsNotRecoverable() {
        // Given: APIキー無効
        let error = RealtimeTranslationError.authenticationFailed

        // When/Then: 自動再接続せず、キー自体はメッセージに含めない
        XCTAssertFalse(error.isRecoverable)
        XCTAssertEqual(error.localizedDescription, "OpenAI APIキーが無効です")
        XCTAssertFalse(error.localizedDescription.contains("sk-"))
    }
}
