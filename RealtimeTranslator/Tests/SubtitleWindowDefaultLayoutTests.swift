import XCTest
@testable import RealtimeTranslator

final class SubtitleWindowDefaultLayoutTests: XCTestCase {
    func testDefaultOriginCentersHorizontallyAboveBottomOffset() {
        // Given: 負座標を含む画面と、中央寄せしたい字幕サイズ
        let visibleFrame = CGRect(x: -300, y: -100, width: 1_000, height: 800)
        let subtitleSize = CGSize(width: 600, height: 120)

        // When: 未保存位置の既定原点を算出する
        let origin = SubtitleWindowGeometry.defaultOrigin(
            in: visibleFrame,
            subtitleSize: subtitleSize
        )

        // Then: 水平中央かつ下端から104pt上へ置く
        XCTAssertEqual(origin.x, -100)
        XCTAssertEqual(origin.y, 4)
    }

    func testEqualOverlapPrefersEarlierScreenIndex() {
        // Given: 左右画面へ面積が同じだけ重なる字幕パネル
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        ]
        let proposedFrame = CGRect(x: 500, y: 100, width: 1_000, height: 200)

        // When: 重なり面積が同点の画面を選ぶ
        let index = SubtitleWindowGeometry.screenIndex(
            bestMatching: proposedFrame,
            in: screenFrames,
            fallbackIndex: 1
        )

        // Then: 同点では先に並んだ画面を選び、fallbackへ飛ばない
        XCTAssertEqual(index, 0)
    }

    func testNoOverlapUsesFallbackScreen() {
        // Given: どの画面とも重ならない提案フレーム
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 800, height: 600)
        ]
        let proposedFrame = CGRect(x: -2_000, y: -1_000, width: 100, height: 80)

        // When: fallback付きで最も重なる画面を選ぶ
        let index = SubtitleWindowGeometry.screenIndex(
            bestMatching: proposedFrame,
            in: screenFrames,
            fallbackIndex: 1
        )

        // Then: 面積0ではfallback画面を使う
        XCTAssertEqual(index, 1)
    }

    func testOversizedLayoutClampsToVisibleOrigin() {
        // Given: 画面より大きい字幕サイズ
        let visibleFrame = CGRect(x: 100, y: 50, width: 400, height: 300)
        let subtitleSize = CGSize(width: 900, height: 500)

        // When: 既定位置へ配置して画面内へクランプする
        let layout = SubtitleWindowGeometry.layout(
            subtitleOrigin: CGPoint(x: 120, y: 80),
            subtitleSize: subtitleSize,
            in: visibleFrame
        )

        // Then: 一体の外接矩形を画面原点へ合わせ、操作パネル間隔を保つ
        XCTAssertEqual(layout.combinedFrame.origin, visibleFrame.origin)
        XCTAssertEqual(
            layout.subtitleFrame.minY - layout.controlFrame.maxY,
            SubtitleWindowGeometry.controlSpacing
        )
    }
}
