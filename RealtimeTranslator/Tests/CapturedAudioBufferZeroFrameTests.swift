@preconcurrency import AVFoundation
import XCTest
@testable import RealtimeTranslator

final class CapturedAudioBufferZeroFrameTests: XCTestCase {
    func testCaptureAcceptsZeroFrameLengthSilence() throws {
        // Given: 無音の0フレーム入力と1slotのバッファプール
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let pool = try XCTUnwrap(
            CapturedAudioBufferPool(
                format: format,
                frameCapacity: 8,
                capacity: 1
            )
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)
        )
        source.frameLength = 0

        // When: 無音バッファを取り込む
        let captured = try XCTUnwrap(pool.capture(source))

        // Then: 形式不一致として捨てず、0フレームのままleaseして返却できる
        XCTAssertEqual(captured.buffer.frameLength, 0)
        XCTAssertEqual(pool.availableCount, 0)
        captured.release()
        XCTAssertEqual(pool.availableCount, 1)
    }
}
