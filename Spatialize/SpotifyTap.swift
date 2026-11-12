import CoreAudio
import Foundation

struct SpatializeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw SpatializeError(message: "\(what) failed (OSStatus \(status))") }
}

private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Reading audio property \(selector)")
    return value
}

/// Captures Spotify's audio with a private process tap and mutes Spotify's own output while capturing.
final class SpotifyTap {
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Creates the tap. Spotify is not muted until `start` begins reading from it.
    init() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size), "Listing audio processes")
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &processes), "Listing audio processes")
        let spotify = try processes.filter {
            let bundle = try read($0, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none)?.takeRetainedValue() as String?
            return bundle?.hasPrefix("com.spotify.client") == true
        }
        if spotify.isEmpty { throw SpatializeError(message: "Spotify isn't running.") }

        description = CATapDescription(stereoMixdownOfProcesses: spotify)
        description.name = "Spatialize"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the Spotify tap")
    }

    /// The tap's stream format; Spatialize requires interleaved stereo Float32.
    func format() throws -> AudioStreamBasicDescription {
        let f = try read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        let isFloat32 = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
        let interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        if !isFloat32 || !interleaved || f.mChannelsPerFrame != 2 {
            throw SpatializeError(message: "Unsupported tap format: \(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel) bit, flags \(f.mFormatFlags)")
        }
        return f
    }

    func start(into ring: Ring) throws {
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spatialize",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID), "Creating the capture device")
        // @Sendable: keeps the block nonisolated so it doesn't trap on the HAL IO thread.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { @Sendable [ring] _, inData, _, _, _ in
            let buffer = inData.pointee.mBuffers  // one interleaved stereo buffer, checked in format()
            guard let data = buffer.mData else { return }
            ring.write(data.assumingMemoryBound(to: Float.self), frameCount: Int(buffer.mDataByteSize) / (2 * MemoryLayout<Float>.size))
        }, "Creating the capture callback")
        try check(AudioDeviceStart(aggID, procID), "Starting capture")
    }

    /// Tears down everything that exists, then throws the first failure.
    func stop() throws {
        var firstError: Error?
        func attempt(_ body: () throws -> Void) { do { try body() } catch { firstError = firstError ?? error } }
        if let procID {
            attempt { try check(AudioDeviceStop(aggID, procID), "Stopping capture") }
            attempt { try check(AudioDeviceDestroyIOProcID(aggID, procID), "Removing the capture callback") }
            self.procID = nil
        }
        if aggID != kAudioObjectUnknown {
            attempt { try check(AudioHardwareDestroyAggregateDevice(aggID), "Removing the capture device") }
            aggID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            attempt { try check(AudioHardwareDestroyProcessTap(tapID), "Removing the Spotify tap") }
            tapID = kAudioObjectUnknown
        }
        if let firstError { throw firstError }
    }
}
