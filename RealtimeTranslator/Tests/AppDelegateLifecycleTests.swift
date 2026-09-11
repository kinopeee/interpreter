import AppKit
import XCTest
@testable import RealtimeTranslator

final class AppDelegateLifecycleTests: XCTestCase {
    func testLastWindowClosedDoesNotTerminateApplication() {
        // Given: 字幕オーバーレイと設定ウィンドウを持つLSUIElementアプリのdelegate
        let delegate = AppDelegate()

        // When: 最後のウィンドウが閉じたあとの終了可否を問い合わせる
        let shouldTerminate = delegate.applicationShouldTerminateAfterLastWindowClosed(
            NSApplication.shared
        )

        // Then: 設定ウィンドウを閉じても録音オーバーレイごと終了しない
        XCTAssertFalse(shouldTerminate)
    }

    func testSecureRestorableStateIsDisabled() {
        // Given: 状態復元を使わないメニューバー常駐アプリのdelegate
        let delegate = AppDelegate()

        // When: Secure Restorable Stateの対応可否を問い合わせる
        let supportsRestore = delegate.applicationSupportsSecureRestorableState(
            NSApplication.shared
        )

        // Then: 復元状態を保存せず、起動経路をdelegate通知だけに依存させない
        XCTAssertFalse(supportsRestore)
    }
}
