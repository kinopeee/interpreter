import XCTest
@testable import RealtimeTranslator

final class SubtitleWindowBoundaryTests: XCTestCase {
    func testPointOnMaxXBelongsToTheNextScreen() {
        // Given: 右端を共有する左右2画面と、ちょうど境界上の保存位置
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        ]
        let boundaryOrigin = CGPoint(x: 1_000, y: 100)

        // When: 原点を含む画面を選ぶ
        let index = SubtitleWindowGeometry.screenIndex(
            containing: boundaryOrigin,
            in: screenFrames,
            fallbackIndex: 0
        )

        // Then: 半開区間のため左画面のmaxXは含めず、右画面へ所属させる
        XCTAssertEqual(index, 1)
    }

    func testControlFrameCentersBelowSubtitleWithFixedGap() {
        // Given: 画面クランプ前の字幕フレーム
        let subtitleFrame = CGRect(x: 120, y: 240, width: 600, height: 160)

        // When: 録音ボタンパネルの位置を算出する
        let controlFrame = SubtitleWindowGeometry.controlFrame(for: subtitleFrame)

        // Then: 字幕下端から8pt空け、水平方向は字幕中央に160x48で置く
        XCTAssertEqual(controlFrame.width, 160)
        XCTAssertEqual(controlFrame.height, 48)
        XCTAssertEqual(controlFrame.midX, subtitleFrame.midX)
        XCTAssertEqual(
            subtitleFrame.minY - controlFrame.maxY,
            SubtitleWindowGeometry.controlSpacing
        )
    }

    func testCombinedFrameUnionsSubtitleAndControl() {
        // Given: 字幕とその下の操作パネル
        let layout = SubtitleWindowLayout(
            subtitleFrame: CGRect(x: 100, y: 200, width: 400, height: 120),
            controlFrame: CGRect(x: 220, y: 144, width: 160, height: 48)
        )

        // When: 一体クランプ用の結合フレームを取る
        let combined = layout.combinedFrame

        // Then: 字幕上端から操作パネル下端までを1つの矩形として扱う
        XCTAssertEqual(combined.minX, 100)
        XCTAssertEqual(combined.maxX, 500)
        XCTAssertEqual(combined.minY, 144)
        XCTAssertEqual(combined.maxY, 320)
    }
}
