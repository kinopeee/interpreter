@preconcurrency import AVFoundation
import XCTest
@testable import RealtimeTranslator

@MainActor
final class AudioBufferOwnershipTests: XCTestCase {
    func testTapYieldsDeepOwnedBufferCopy() async throws {
        // Given: 2チャンネルの非インターリーブ音声とtapの非同期ストリーム
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        source.frameLength = 4
        let sourceChannels = try XCTUnwrap(source.floatChannelData)
        sourceChannels[0][0] = 1.25
        sourceChannels[1][3] = 2.5
        let (stream, continuation) = AsyncStream<CapturedAudioBuffer>.makeStream()
        let bufferPool = try XCTUnwrap(
            CapturedAudioBufferPool(
                format: format,
                frameCapacity: 4,
                capacity: 1
            )
        )
        let tap = AnalyzerAudioTap(
            continuation: continuation,
            bufferPool: bufferPool
        )

        // When: tapへ渡した直後に音声エンジン所有の元バッファを書き換える
        tap.receive(source)
        sourceChannels[0][0] = 9
        sourceChannels[1][3] = 10
        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        let captured = try XCTUnwrap(next)

        // Then: 非同期側は別オブジェクトで変更前の全チャンネル値を保持する
        let capturedChannels = try XCTUnwrap(captured.buffer.floatChannelData)
        XCTAssertFalse(captured.buffer === source)
        XCTAssertEqual(captured.buffer.frameLength, 4)
        XCTAssertEqual(capturedChannels[0][0], 1.25)
        XCTAssertEqual(capturedChannels[1][3], 2.5)
        XCTAssertEqual(bufferPool.availableCount, 0)

        // When: consumerが返却したslotへ次の音声を取り込む
        captured.release()
        sourceChannels[0][0] = 3.75
        tap.receive(source)
        let reusedValue = await iterator.next()
        let reused = try XCTUnwrap(reusedValue)
        continuation.finish()

        // Then: callbackごとに確保せず、同じ事前確保slotを再利用する
        XCTAssertTrue(reused === captured)
        XCTAssertEqual(reused.buffer.floatChannelData?[0][0], 3.75)
        reused.release()
        XCTAssertEqual(bufferPool.availableCount, 1)
    }

    func testPoolKeepsSpareSlotForBufferingNewestReplacement() async throws {
        // Given: 1件stream・1件consumer処理中・1件予備の3slotを持つtap
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        )
        source.frameLength = 1
        let sourceData = try XCTUnwrap(source.floatChannelData)
        let (stream, continuation) = AsyncStream<CapturedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let pool = try XCTUnwrap(
            CapturedAudioBufferPool(
                format: format,
                frameCapacity: 1,
                capacity: 3
            )
        )
        let tap = AnalyzerAudioTap(continuation: continuation, bufferPool: pool)

        // When: 1件を処理中に、streamへ新旧2bufferを連続投入する
        sourceData[0][0] = 1
        tap.receive(source)
        var iterator = stream.makeAsyncIterator()
        let processingValue = await iterator.next()
        let processing = try XCTUnwrap(processingValue)
        sourceData[0][0] = 2
        tap.receive(source)
        sourceData[0][0] = 3
        tap.receive(source)
        let newestValue = await iterator.next()
        let newest = try XCTUnwrap(newestValue)
        continuation.finish()

        // Then: 待機中の最古slotを返却し、処理中でも最新音声を保持する
        XCTAssertEqual(processing.buffer.floatChannelData?[0][0], 1)
        XCTAssertEqual(newest.buffer.floatChannelData?[0][0], 3)
        XCTAssertEqual(pool.availableCount, 1)
        processing.release()
        newest.release()
        XCTAssertEqual(pool.availableCount, 3)
    }

    func testPoolRejectsNonPositiveCapacity() throws {
        // Given: 有効なFloat32音声形式
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )

        // When: フレーム数またはslot数が0のプールを作る
        // Then: 不正容量を黙って確保せず失敗する
        XCTAssertNil(
            CapturedAudioBufferPool(format: format, frameCapacity: 0, capacity: 1)
        )
        XCTAssertNil(
            CapturedAudioBufferPool(format: format, frameCapacity: 1, capacity: 0)
        )
    }

    func testCaptureRejectsFormatMismatchAndOversizedFrames() throws {
        // Given: 16kHz・2フレームのプール
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let pool = try XCTUnwrap(
            CapturedAudioBufferPool(format: format, frameCapacity: 2, capacity: 1)
        )
        let mismatchedFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let mismatched = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: mismatchedFormat, frameCapacity: 2)
        )
        mismatched.frameLength = 2
        let oversized = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        oversized.frameLength = 4

        // When: 標本レート違いと容量超過のバッファを取り込む
        let mismatchedCapture = pool.capture(mismatched)
        let oversizedCapture = pool.capture(oversized)

        // Then: 所有権を渡さず、slotを消費しない
        XCTAssertNil(mismatchedCapture)
        XCTAssertNil(oversizedCapture)
        XCTAssertEqual(pool.availableCount, 1)
    }

    func testDoubleReleaseDoesNotInflateAvailableCount() throws {
        // Given: 1slotのプールから借り出したバッファ
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let pool = try XCTUnwrap(
            CapturedAudioBufferPool(format: format, frameCapacity: 1, capacity: 1)
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        )
        source.frameLength = 1
        let captured = try XCTUnwrap(pool.capture(source))
        XCTAssertEqual(pool.availableCount, 0)

        // When: 同じleaseを2回返す
        captured.release()
        captured.release()

        // Then: slot数が容量を超えて増えない
        XCTAssertEqual(pool.availableCount, 1)
    }

    func testTapDropsAudioWhenPoolIsExhausted() async throws {
        // Given: 1slotしかないtap
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        )
        source.frameLength = 1
        let sourceData = try XCTUnwrap(source.floatChannelData)
        sourceData[0][0] = 1
        let (stream, continuation) = AsyncStream<CapturedAudioBuffer>.makeStream()
        let pool = try XCTUnwrap(
            CapturedAudioBufferPool(format: format, frameCapacity: 1, capacity: 1)
        )
        let tap = AnalyzerAudioTap(continuation: continuation, bufferPool: pool)
        tap.receive(source)

        // When: 返却前に次の音声が届く
        sourceData[0][0] = 2
        tap.receive(source)
        continuation.finish()

        // Then: 2件目は黙って捨て、既存leaseを壊さない
        XCTAssertEqual(pool.availableCount, 0)
        var iterator = stream.makeAsyncIterator()
        let first = try XCTUnwrap(await iterator.next())
        XCTAssertEqual(first.buffer.floatChannelData?[0][0], 1)
        XCTAssertNil(await iterator.next())
        first.release()
        XCTAssertEqual(pool.availableCount, 1)
    }
}
