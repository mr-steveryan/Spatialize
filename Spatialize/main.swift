// Spike: prove a Core Audio process tap can capture Spotify on this macOS.
// Run via `open Spatialize.app` (optionally `--args muted`). Logs to ~/Library/Logs/Spatialize-spike.log.
import CoreAudio
import Foundation
import os

let logPath = NSHomeDirectory() + "/Library/Logs/Spatialize-spike.log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logFile = FileHandle(forWritingAtPath: logPath)!

func log(_ s: String) {
    logFile.write((s + "\n").data(using: .utf8)!)
}

func fail(_ s: String) -> Never {
    log("FAIL: \(s)")
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) returned OSStatus \(status)") }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, _ what: String) -> T {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), what)
    return value
}

let muted = CommandLine.arguments.contains("muted")
let seconds = CommandLine.arguments.dropFirst().compactMap { Int($0) }.first ?? 10
log("Spatialize spike start, muted=\(muted) seconds=\(seconds)")

// 1. List every audio process and pick Spotify's.
let system = AudioObjectID(kAudioObjectSystemObject)
var listAddr = address(kAudioHardwarePropertyProcessObjectList)
var listSize: UInt32 = 0
check(AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &listSize), "process list size")
var processes = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
check(AudioObjectGetPropertyData(system, &listAddr, 0, nil, &listSize, &processes), "process list")

var spotify: [AudioObjectID] = []
var spotifyPlaying = false
for p in processes {
    let pid = read(p, kAudioProcessPropertyPID, pid_t(0), "pid of \(p)")
    let bundle = read(p, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none, "bundle of \(p)")?.takeRetainedValue() as String? ?? ""
    let running = read(p, kAudioProcessPropertyIsRunningOutput, UInt32(0), "running of \(p)") != 0
    log("process obj=\(p) pid=\(pid) bundle=\(bundle) runningOutput=\(running)")
    if bundle.hasPrefix("com.spotify.client") {
        spotify.append(p)
        spotifyPlaying = spotifyPlaying || running
    }
}
if spotify.isEmpty { fail("no Spotify audio process found") }
if !spotifyPlaying { fail("Spotify isn't playing; start playback and rerun") }

// 2. Create the tap.
let desc = CATapDescription(stereoMixdownOfProcesses: spotify)
desc.name = "Spatialize spike tap"
desc.uuid = UUID()
desc.isPrivate = true
desc.muteBehavior = muted ? .mutedWhenTapped : .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")
let format = read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription(), "tap format")
log("tap id=\(tapID) format: rate=\(format.mSampleRate) ch=\(format.mChannelsPerFrame) bits=\(format.mBitsPerChannel) flags=\(format.mFormatFlags)")
if format.mFormatFlags & kAudioFormatFlagIsFloat == 0 || format.mBitsPerChannel != 32 {
    fail("tap format is not Float32, spike only handles Float32")
}

// 3. Tap-only private aggregate device to read from.
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Spatialize spike",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID), "AudioHardwareCreateAggregateDevice")
log("aggregate id=\(aggID)")

// 4. Measure peak level in the IO proc.
struct Meter { var callbacks = 0; var peak: Float = 0 }
// shortcut: lock on the audio thread is fine for a spike, use a lock-free ring buffer in the real engine.
let meter = OSAllocatedUnfairLock(initialState: Meter())
var procID: AudioDeviceIOProcID?
// @Sendable: top-level closures default to MainActor and trap when CoreAudio calls them on its IO thread.
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { @Sendable [meter] _, inData, _, _, _ in
    var peak: Float = 0
    for buf in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)) {
        guard let data = buf.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(buf.mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[i])) }
    }
    let blockPeak = peak
    meter.withLock { $0.callbacks += 1; $0.peak = max($0.peak, blockPeak) }
}, "AudioDeviceCreateIOProcIDWithBlock")
check(AudioDeviceStart(aggID, procID), "AudioDeviceStart")
log("started, measuring for \(seconds) s")

// A drop to 16/24 kHz means Bluetooth headphones fell into low-quality headset mode.
let outputDevice = read(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0), "default output device")
var maxPeak: Float = 0
for second in 1...seconds {
    Thread.sleep(forTimeInterval: 1)
    let m = meter.withLock { m in defer { m = Meter() }; return m }
    maxPeak = max(maxPeak, m.peak)
    let outRate = read(outputDevice, kAudioDevicePropertyNominalSampleRate, Float64(0), "output sample rate")
    log("t=\(second)s callbacks=\(m.callbacks) peak=\(m.peak) outputRate=\(outRate)")
}

// 5. Clean up.
check(AudioDeviceStop(aggID, procID), "AudioDeviceStop")
check(AudioDeviceDestroyIOProcID(aggID, procID!), "AudioDeviceDestroyIOProcID")
check(AudioHardwareDestroyAggregateDevice(aggID), "AudioHardwareDestroyAggregateDevice")
check(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")

if maxPeak > 0 {
    log("PASS: max peak \(maxPeak)")
    exit(0)
}
fail("callbacks ran but all samples were zero (permission denied, or nothing captured)")
