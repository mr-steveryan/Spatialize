import AVFAudio
import XCTest
@testable import Spatialize

final class RingTests: XCTestCase {
    func testPrimesThenReadsInOrderAndCountsUnderrunAndOverrun() {
        let ring = Ring(capacityFrames: 4, primeFrames: 2)
        var l = [Float](repeating: -1, count: 2), r = l

        ring.read(left: &l, right: &r, frameCount: 2)  // not primed yet: silence, no underrun
        XCTAssertEqual(l, [0, 0])
        XCTAssertEqual(ring.stats, Ring.Stats())

        let frames: [Float] = [1, -1, 2, -2, 3, -3]  // 3 interleaved frames
        ring.write(frames, frameCount: 3)
        ring.read(left: &l, right: &r, frameCount: 2)
        XCTAssertEqual(l, [1, 2])
        XCTAssertEqual(r, [-1, -2])

        ring.read(left: &l, right: &r, frameCount: 2)  // only 1 frame left
        XCTAssertEqual(l, [0, 0])
        XCTAssertEqual(ring.stats.underruns, 1)

        ring.write([4, -4, 5, -5, 6, -6, 7, -7], frameCount: 4)  // 1 + 4 > 4: drops frame 3
        XCTAssertEqual(ring.stats.overruns, 1)
        ring.read(left: &l, right: &r, frameCount: 2)
        XCTAssertEqual(l, [4, 5])
    }
}

final class SpatializerTests: XCTestCase {
    /// A left-only click must reach both ears, the right one later.
    /// Stereo passthrough leaves the right channel silent; plain panning has no time delay.
    func testLeftOnlyClickIsRenderedBinaurally() throws {
        let rate = 48_000.0, frames = 8192, clickAt = 1000
        let ring = Ring(capacityFrames: frames, primeFrames: 1)
        var input = [Float](repeating: 0, count: frames * 2)
        input[clickAt * 2] = 1
        ring.write(input, frameCount: frames)

        let spatializer = try Spatializer(sampleRate: rate, ring: ring)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try spatializer.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(frames))
        try spatializer.start()
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: spatializer.engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames)))
        XCTAssertEqual(try spatializer.engine.renderOffline(AVAudioFrameCount(frames), to: out), .success)

        // Our settings survived engine start (personalized HRTF requires UseOutputType + headphones).
        let state = try spatializer.mixerState()
        print("mixer state \(state)")
        XCTAssertEqual(state.algorithm, 7)  // kSpatializationAlgorithm_UseOutputType (AudioUnitProperties.h)
        XCTAssertEqual(state.outputType, 1)  // kSpatialMixerOutputType_Headphones
        XCTAssertEqual(state.personalizedMode, AUSpatialMixerPersonalizedHRTFMode.on.rawValue)

        let channels = try XCTUnwrap(out.floatChannelData)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: frames)).map(abs)
        let right = Array(UnsafeBufferPointer(start: channels[1], count: frames)).map(abs)
        let leftPeak = try XCTUnwrap(left.indices.max { left[$0] < left[$1] })
        let rightPeak = try XCTUnwrap(right.indices.max { right[$0] < right[$1] })
        print("left peak \(left[leftPeak]) at \(leftPeak), right peak \(right[rightPeak]) at \(rightPeak)")

        XCTAssertGreaterThan(right[rightPeak], 0.01, "right ear silent: not spatialized")
        XCTAssertGreaterThan(left[leftPeak], right[rightPeak], "left click should be louder on the left")
        XCTAssertGreaterThan(rightPeak, leftPeak, "no interaural delay: panning, not HRTF")
    }
}
