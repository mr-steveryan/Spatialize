import AVFAudio
import AudioToolbox

/// Renders the captured stereo as two virtual speakers around the listener (HRTF) and plays it.
final class Spatializer {
    /// What the underlying AUSpatialMixer is actually doing, read back after start.
    struct MixerState: Equatable {
        var algorithm: UInt32
        var outputType: UInt32
        var personalizedMode: UInt32
        var usingPersonalizedHRTF: Bool
    }

    let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let source: AVAudioSourceNode
    private let mixer: AudioUnit

    init(sampleRate: Double, ring: Ring) throws {
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo) else {
            throw SpatializeError(message: "Couldn't create a stereo channel layout")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        // @Sendable: keeps the block nonisolated so it doesn't trap on the render thread.
        source = AVAudioSourceNode(format: format) { @Sendable [ring] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count == 2, let l = buffers[0].mData, let r = buffers[1].mData else { return kAudioUnitErr_InvalidParameter }
            ring.read(left: l.assumingMemoryBound(to: Float.self), right: r.assumingMemoryBound(to: Float.self), frameCount: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.attach(environment)
        engine.connect(source, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        // Ambience bed places each input channel as a far-field speaker, per the stereo layout.
        // .auto = kSpatializationAlgorithm_UseOutputType, which personalized HRTF requires.
        source.sourceMode = .ambienceBed
        source.renderingAlgorithm = .auto
        environment.outputType = .headphones

        // The environment node doesn't expose personalized HRTF, so set it on its AUSpatialMixer.
        guard let bridge = environment.auAudioUnit as? AUAudioUnitV2Bridge,
              bridge.componentDescription.componentSubType == kAudioUnitSubType_SpatialMixer else {
            throw SpatializeError(message: "The environment node isn't backed by AUSpatialMixer")
        }
        mixer = bridge.audioUnit
        var mode = AUSpatialMixerPersonalizedHRTFMode.on.rawValue
        try check(AudioUnitSetProperty(mixer, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global, 0, &mode, UInt32(MemoryLayout<UInt32>.size)), "Enabling personalized HRTF")
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }

    func mixerState() throws -> MixerState {
        func get(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope) throws -> UInt32 {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitGetProperty(mixer, property, scope, 0, &value, &size), "Reading spatial mixer property \(property)")
            return value
        }
        return MixerState(
            algorithm: try get(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input),
            outputType: try get(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global),
            personalizedMode: try get(kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global),
            usingPersonalizedHRTF: try get(kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF, kAudioUnitScope_Global) != 0
        )
    }
}
