@preconcurrency import AVFoundation
import XCTest
@testable import RealtimeTranslator

final class AnalyzerAudioTapTerminationTests: XCTestCase {
    func testReceiveAfterStreamFinishReleasesCapturedBuffer() throws {
        // Given: 終了済みの音声ストリームへ接続したtapと、空き1slotのプール
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)
        )
        source.frameLength = 2
        try XCTUnwrap(source.floatChannelData)[0][0] = 0.5
        let (_, continuation) = AsyncStream<CapturedAudioBuffer>.makeStream()
        let pool = try XCTUnwrap(
            CapturedAudioBufferPool(
                format: format,
                frameCapacity: 2,
                capacity: 1
            )
        )
        let tap = AnalyzerAudioTap(
            continuation: continuation,
            bufferPool: pool
        )
        continuation.finish()

        // When: ストリーム終了後に音声エンジンからバッファが届く
        tap.receive(source)

        // Then: 終了済みyieldのバッファをリークせずslotへ戻す
        XCTAssertEqual(pool.availableCount, 1)
    }
}
