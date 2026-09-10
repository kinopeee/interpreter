import XCTest
@testable import RealtimeTranslator

final class PendingTranslationRequestRaceTests: XCTestCase {
    func testSuccessBeforeInstallResumesWithSuccess() async throws {
        // Given: continuation設置前に翻訳結果が届いた依頼
        let request = PendingTranslationRequest(text: "ready", priority: .final)
        request.complete(with: .success("Translated"))

        // When: 後からcontinuationを設置する
        let translated = try await withCheckedThrowingContinuation { continuation in
            let installed = request.install(continuation)
            XCTAssertFalse(installed)
        }

        // Then: 待機側をhungさせず、先に届いた成功結果を返す
        XCTAssertEqual(translated, "Translated")
        XCTAssertFalse(request.isActive)
    }

    func testSecondCompleteIsIgnoredAfterSuccess() async throws {
        // Given: すでに成功完了した翻訳依頼
        let request = PendingTranslationRequest(text: "once", priority: .live)
        request.complete(with: .success("first"))

        // When: 別の成功と取消を重ねて通知し、continuationを設置する
        request.complete(with: .success("second"))
        request.cancel()
        let translated = try await withCheckedThrowingContinuation { continuation in
            XCTAssertFalse(request.install(continuation))
        }

        // Then: 最初の成功だけを保持し、後続の上書きや取消を無視する
        XCTAssertEqual(translated, "first")
        XCTAssertFalse(request.isActive)
    }
}
