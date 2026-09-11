@preconcurrency import AVFoundation
import XCTest
@testable import RealtimeTranslator

final class AnalyzerAudioConverterSerialReuseTests: XCTestCase {
    func testSerialConversionsKeepIndependentSampleValues() throws {
        // Given: 同じ入出力形式の状態付き変換器と、値が異なる2つの入力バッファ
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let converter = try XCTUnwrap(
            AnalyzerAudioConverter(inputFormat: format, outputFormat: format)
        )
        let firstSource = try makeBuffer(format: format, value: 0.25)
        let secondSource = try makeBuffer(format: format, value: -0.5)

        // When: 単一変換器へ直列に2回convertする
        let firstOutput = try converter.convert(firstSource)
        let secondOutput = try converter.convert(secondSource)

        // Then: 内部状態を持ち越さず、各入力の先頭サンプルを独立にコピーする
        XCTAssertEqual(firstOutput.frameLength, 4)
        XCTAssertEqual(secondOutput.frameLength, 4)
        XCTAssertEqual(firstOutput.floatChannelData?[0][0], 0.25)
        XCTAssertEqual(secondOutput.floatChannelData?[0][0], -0.5)
        XCTAssertFalse(firstOutput === secondOutput)
    }

    private func makeBuffer(
        format: AVAudioFormat,
        value: Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        try XCTUnwrap(buffer.floatChannelData)[0][0] = value
        return buffer
    }
}
