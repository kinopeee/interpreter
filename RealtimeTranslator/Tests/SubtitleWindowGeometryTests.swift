import XCTest
@testable import RealtimeTranslator

final class SubtitleWindowGeometryTests: XCTestCase {
    func testUsesMeasuredContentHeightWhenItFits() {
        // Given: 録音ボタンを含めても画面内に収まる字幕内容高
        let visibleFrame = CGRect(x: -300, y: -100, width: 1_000, height: 700)

        // When: 字幕パネル高を算出する
        let height = SubtitleWindowGeometry.subtitleHeight(
            measuredContentHeight: 321.2,
            in: visibleFrame
        )

        // Then: ピクセル境界へ切り上げた内容高をそのまま採用する
        XCTAssertEqual(height, 322)
    }

    func testCapsContentHeightBelowControlPanel() {
        // Given: 画面の利用可能高を超える字幕内容高
        let visibleFrame = CGRect(x: -300, y: -100, width: 1_000, height: 700)

        // When: 字幕パネル高を算出する
        let height = SubtitleWindowGeometry.subtitleHeight(
            measuredContentHeight: 900,
            in: visibleFrame
        )

        // Then: 48ptの操作パネルと8ptの間隔を除いた高さへ制限する
        XCTAssertEqual(height, 644)
    }

    func testSelectsNegativeCoordinateSecondaryScreen() {
        // Given: 原点が負座標にある副画面と、その画面内の保存位置
        let screenFrames = [
            CGRect(x: 200, y: 0, width: 1_400, height: 900),
            CGRect(x: -1_720, y: -120, width: 1_920, height: 1_080)
        ]
        let savedOrigin = CGPoint(x: -1_200, y: 80)

        // When: 保存位置を含む画面を選択する
        let index = SubtitleWindowGeometry.screenIndex(
            containing: savedOrigin,
            in: screenFrames,
            fallbackIndex: 0
        )

        // Then: 負座標の副画面を選択する
        XCTAssertEqual(index, 1)
    }

    func testFallsBackWhenSavedOriginIsOutsideAllScreens() {
        // Given: 接続中のどの画面にも含まれない保存位置
        let screenFrames = [
            CGRect(x: 100, y: 100, width: 800, height: 600),
            CGRect(x: 900, y: 100, width: 1_000, height: 700)
        ]
        let savedOrigin = CGPoint(x: -2_000, y: -1_000)

        // When: fallbackを指定して画面を選択する
        let index = SubtitleWindowGeometry.screenIndex(
            containing: savedOrigin,
            in: screenFrames,
            fallbackIndex: 1
        )

        // Then: 指定したfallback画面を選択する
        XCTAssertEqual(index, 1)
    }

    func testSelectsAdjacentScreenBeforePanelOriginCrossesBoundary() {
        // Given: 原点は左画面内だが、面積の大半が右画面へ移った字幕パネル
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        ]
        let proposedFrame = CGRect(x: 800, y: 200, width: 600, height: 200)

        // When: パネルとの重なり面積からドラッグ先画面を選択する
        let index = SubtitleWindowGeometry.screenIndex(
            bestMatching: proposedFrame,
            in: screenFrames,
            fallbackIndex: 0
        )

        // Then: 原点の境界通過を待たず、大半が属する右画面を選択する
        XCTAssertEqual(index, 1)
    }

    func testClampsBothPanelsAtLeftEdge() {
        // Given: 字幕パネルが画面左端から50ptはみ出す配置
        let visibleFrame = testVisibleFrame

        // When: 字幕と操作パネルを一体で配置する
        let layout = SubtitleWindowGeometry.layout(
            subtitleOrigin: CGPoint(x: -350, y: 0),
            subtitleSize: testSubtitleSize,
            in: visibleFrame
        )

        // Then: 字幕を左端へ寄せ、操作パネルとの8pt間隔を保つ
        XCTAssertEqual(layout.subtitleFrame.minX, visibleFrame.minX)
        XCTAssertEqual(layout.combinedFrame.minX, visibleFrame.minX)
        assertControlSpacing(in: layout)
    }

    func testClampsBothPanelsAtRightEdge() {
        // Given: 字幕パネルが画面右端から50ptはみ出す配置
        let visibleFrame = testVisibleFrame

        // When: 字幕と操作パネルを一体で配置する
        let layout = SubtitleWindowGeometry.layout(
            subtitleOrigin: CGPoint(x: 150, y: 0),
            subtitleSize: testSubtitleSize,
            in: visibleFrame
        )

        // Then: 字幕を右端へ寄せ、操作パネルとの8pt間隔を保つ
        XCTAssertEqual(layout.subtitleFrame.maxX, visibleFrame.maxX)
        XCTAssertEqual(layout.combinedFrame.maxX, visibleFrame.maxX)
        assertControlSpacing(in: layout)
    }

    func testClampsBothPanelsAtBottomEdge() {
        // Given: 字幕の下にある操作パネルが画面下端からはみ出す配置
        let visibleFrame = testVisibleFrame

        // When: 字幕と操作パネルを一体で配置する
        let layout = SubtitleWindowGeometry.layout(
            subtitleOrigin: CGPoint(x: -100, y: -240),
            subtitleSize: testSubtitleSize,
            in: visibleFrame
        )

        // Then: 操作パネルを下端へ寄せ、字幕との8pt間隔を保つ
        XCTAssertEqual(layout.controlFrame.minY, visibleFrame.minY)
        XCTAssertEqual(layout.combinedFrame.minY, visibleFrame.minY)
        assertControlSpacing(in: layout)
    }

    func testClampsBothPanelsAtTopEdge() {
        // Given: 字幕パネルが画面上端からはみ出す配置
        let visibleFrame = testVisibleFrame

        // When: 字幕と操作パネルを一体で配置する
        let layout = SubtitleWindowGeometry.layout(
            subtitleOrigin: CGPoint(x: -100, y: 400),
            subtitleSize: testSubtitleSize,
            in: visibleFrame
        )

        // Then: 字幕パネルを上端へ寄せ、操作パネルとの8pt間隔を保つ
        XCTAssertEqual(layout.subtitleFrame.maxY, visibleFrame.maxY)
        XCTAssertEqual(layout.combinedFrame.maxY, visibleFrame.maxY)
        assertControlSpacing(in: layout)
    }

    func testControlPositionDoesNotMoveAsSubtitleGrows() {
        // Given: 同じ下端位置にある短い字幕と長い字幕
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let subtitleOrigin = CGPoint(x: 200, y: 104)

        // When: 内容高だけが変化したレイアウトを算出する
        let shortLayout = SubtitleWindowGeometry.layout(
            subtitleOrigin: subtitleOrigin,
            subtitleSize: CGSize(width: 600, height: 120),
            in: visibleFrame
        )
        let tallLayout = SubtitleWindowGeometry.layout(
            subtitleOrigin: subtitleOrigin,
            subtitleSize: CGSize(width: 600, height: 500),
            in: visibleFrame
        )

        // Then: 録音操作パネルは字幕下端を基準に同じ位置を保つ
        XCTAssertEqual(tallLayout.controlFrame, shortLayout.controlFrame)
        assertControlSpacing(in: tallLayout)
    }

    private var testVisibleFrame: CGRect {
        CGRect(x: -300, y: -200, width: 1_000, height: 800)
    }

    private var testSubtitleSize: CGSize {
        CGSize(width: 600, height: 200)
    }

    private func assertControlSpacing(
        in layout: SubtitleWindowLayout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            layout.subtitleFrame.minY - layout.controlFrame.maxY,
            SubtitleWindowGeometry.controlSpacing,
            file: file,
            line: line
        )
        XCTAssertEqual(
            layout.controlFrame.midX,
            layout.subtitleFrame.midX,
            file: file,
            line: line
        )
    }
}
