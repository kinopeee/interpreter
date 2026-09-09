@preconcurrency import AVFoundation
import XCTest
@testable import RealtimeTranslator

@MainActor
final class AnalyzerAudioConverterTests: XCTestCase {
    func testSameFormatConversionCopiesSampleValues() throws {
        // Given: 入力と出力が同じ48kHz Float32モノラルの変換器
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let converter = try XCTUnwrap(
            AnalyzerAudioConverter(inputFormat: format, outputFormat: format)
        )
        let input = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        input.frameLength = 4
        let samples = try XCTUnwrap(input.floatChannelData)
        samples[0][0] = 0.25
        samples[0][1] = -0.5
        samples[0][2] = 0.75
        samples[0][3] = -1.0

        // When: 同じ形式のまま変換する
        let output = try converter.convert(input)

        // Then: フレーム数とサンプル値を保持した別バッファを返す
        let outputSamples = try XCTUnwrap(output.floatChannelData)
        XCTAssertFalse(output === input)
        XCTAssertEqual(output.frameLength, 4)
        XCTAssertEqual(output.format.sampleRate, 48_000)
        XCTAssertEqual(outputSamples[0][0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(outputSamples[0][1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(outputSamples[0][2], 0.75, accuracy: 0.0001)
        XCTAssertEqual(outputSamples[0][3], -1.0, accuracy: 0.0001)
    }

    func testDownsampleConversionProducesNonEmptyOutput() throws {
        // Given: 48kHz入力を16kHzへ落とす変換器と480フレームの無音
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let outputFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let converter = try XCTUnwrap(
            AnalyzerAudioConverter(
                inputFormat: inputFormat,
                outputFormat: outputFormat
            )
        )
        let input = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480)
        )
        input.frameLength = 480

        // When: 認識用の低いサンプリングレートへ変換する
        let output = try converter.convert(input)

        // Then: 例外なく16kHzバッファを返し、無音入力でもフレームを落とさない
        XCTAssertEqual(output.format.sampleRate, 16_000)
        XCTAssertGreaterThanOrEqual(output.frameLength, 1)
        XCTAssertLessThanOrEqual(output.frameLength, 480)
    }
}
