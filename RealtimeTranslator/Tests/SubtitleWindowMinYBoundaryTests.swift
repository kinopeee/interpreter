import XCTest
@testable import RealtimeTranslator

final class SubtitleWindowMinYBoundaryTests: XCTestCase {
    func testPointOnMinYBelongsToCurrentScreen() {
        // Given: 縦に隣接する2画面と、下画面のminY上の原点
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 0, y: 1_080, width: 1_920, height: 1_080)
        ]
        let origin = CGPoint(x: 200, y: 0)

        // When: 原点を含む画面を選ぶ
        let index = SubtitleWindowGeometry.screenIndex(
            containing: origin,
            in: screenFrames,
            fallbackIndex: 1
        )

        // Then: minYは含む側なので下画面を選ぶ
        XCTAssertEqual(index, 0)
    }

    func testPointJustBelowMaxYStaysOnCurrentScreen() {
        // Given: 下画面の上端直前にある原点
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 0, y: 1_080, width: 1_920, height: 1_080)
        ]
        let origin = CGPoint(x: 200, y: 1_079.5)

        // When: 原点を含む画面を選ぶ
        let index = SubtitleWindowGeometry.screenIndex(
            containing: origin,
            in: screenFrames,
            fallbackIndex: 1
        )

        // Then: maxY直前はまだ下画面に属する
        XCTAssertEqual(index, 0)
    }
}
