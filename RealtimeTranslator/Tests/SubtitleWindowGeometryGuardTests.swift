import XCTest
@testable import RealtimeTranslator

final class SubtitleWindowGeometryGuardTests: XCTestCase {
    func testInvalidFallbackIndexUsesFirstScreen() {
        // Given: 保存位置がどの画面にも含まれず、fallback番号も不正な状態
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 1_000, height: 700)
        ]
        let savedOrigin = CGPoint(x: -2_000, y: -1_000)

        // When: 範囲外と負のfallbackで画面を選択する
        let tooLarge = SubtitleWindowGeometry.screenIndex(
            containing: savedOrigin,
            in: screenFrames,
            fallbackIndex: 99
        )
        let negative = SubtitleWindowGeometry.screenIndex(
            containing: savedOrigin,
            in: screenFrames,
            fallbackIndex: -1
        )
        let valid = SubtitleWindowGeometry.screenIndex(
            containing: savedOrigin,
            in: screenFrames,
            fallbackIndex: 1
        )

        // Then: 不正fallbackは先頭画面へ倒し、有効なfallbackだけを尊重する
        XCTAssertEqual(tooLarge, 0)
        XCTAssertEqual(negative, 0)
        XCTAssertEqual(valid, 1)
    }

    func testInvalidFallbackIndexForBestMatchUsesFirstScreen() {
        // Given: どの画面とも重ならない提案フレーム
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 1_000, height: 700)
        ]
        let proposedFrame = CGRect(x: -5_000, y: -5_000, width: 10, height: 10)

        // When: 面積一致がなく、fallbackも範囲外
        let index = SubtitleWindowGeometry.screenIndex(
            bestMatching: proposedFrame,
            in: screenFrames,
            fallbackIndex: 99
        )

        // Then: nilを返さず先頭画面へ倒す
        XCTAssertEqual(index, 0)
    }

    func testNegativeVisibleWidthProducesZeroSubtitleWidth() {
        // Given: 幅が負の可視領域
        let visibleFrame = CGRect(x: 0, y: 0, width: -100, height: 800)

        // When: 字幕パネル幅を算出する
        let width = SubtitleWindowGeometry.subtitleWidth(in: visibleFrame)

        // Then: 負のフレームを作らず0へクランプする
        XCTAssertEqual(width, 0)
    }

    func testNegativeMeasuredHeightAndTinyScreenProduceZeroSubtitleHeight() {
        // Given: 負の内容高と、操作パネルより低い可視領域
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 40)

        // When: 字幕パネル高を算出する
        let negativeMeasured = SubtitleWindowGeometry.subtitleHeight(
            measuredContentHeight: -20,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let tinyScreen = SubtitleWindowGeometry.subtitleHeight(
            measuredContentHeight: 200,
            in: visibleFrame
        )

        // Then: 負値と不足高を0へクランプし、操作パネルを押し出さない
        XCTAssertEqual(negativeMeasured, 0)
        XCTAssertEqual(tinyScreen, 0)
    }
}
