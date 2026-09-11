import XCTest
@testable import RealtimeTranslator

final class SubtitleWindowVerticalBoundaryTests: XCTestCase {
    func testPointOnMaxYBelongsToTheNextScreen() {
        // Given: 上下に接する2画面と、共有する上端maxY上の原点
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 0, y: 800, width: 1_000, height: 800)
        ]
        let originOnSharedEdge = CGPoint(x: 100, y: 800)

        // When: 保存位置を含む画面を選択する
        let index = SubtitleWindowGeometry.screenIndex(
            containing: originOnSharedEdge,
            in: screenFrames,
            fallbackIndex: 0
        )

        // Then: maxYは排他なので共有辺は上の画面に属する
        XCTAssertEqual(index, 1)
    }

    func testPointOnMinXBelongsToCurrentScreen() {
        // Given: 左右に接する2画面と、右画面の左端minX上の原点
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        ]
        let originOnRightMinX = CGPoint(x: 1_000, y: 100)

        // When: 保存位置を含む画面を選択する
        let index = SubtitleWindowGeometry.screenIndex(
            containing: originOnRightMinX,
            in: screenFrames,
            fallbackIndex: 0
        )

        // Then: minXはinclusiveなので境界点は右画面に属する
        XCTAssertEqual(index, 1)
    }
}
