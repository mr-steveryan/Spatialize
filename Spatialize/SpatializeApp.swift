import AVFAudio
import SwiftUI
import os

private let logger = Logger(subsystem: "com.mrsteve.spatialize", category: "audio")

@main
struct SpatializeApp: App {
    @State private var controller = Controller()

    var body: some Scene {
        MenuBarExtra("Spatialize", systemImage: controller.isOn ? "headphones.circle.fill" : "headphones") {
            Toggle("Spatial Audio for Spotify", isOn: Binding(get: { controller.isOn }, set: { controller.set(on: $0) }))
            if controller.isOn, let inUse = controller.profileInUse {
                Text(inUse ? "Using your personal ear profile" : "Personal ear profile unavailable, using generic")
            }
            if let error = controller.error {
                Text(error)
            }
            Divider()
            Button("Quit Spatialize") {
                controller.set(on: false)
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@MainActor @Observable
final class Controller {
    private(set) var isOn = false
    private(set) var error: String?
    private(set) var profileInUse: Bool?

    private var tap: SpotifyTap?
    private var spatializer: Spatializer?
    private var ring: Ring?
    private var configObserver: NSObjectProtocol?
    private var statsTimer: Timer?

    func set(on: Bool) {
        if on == isOn { return }
        on ? start() : stop(reason: nil)
    }

    private func start() {
        error = nil
        do {
            let tap = try SpotifyTap()
            self.tap = tap
            let format = try tap.format()
            let ring = Ring(capacityFrames: Int(format.mSampleRate / 2), primeFrames: 2048)
            self.ring = ring
            let spatializer = try Spatializer(sampleRate: format.mSampleRate, ring: ring)
            self.spatializer = spatializer
            // Engine first, tap second: Spotify is only muted once something is ready to play it.
            try spatializer.start()
            try tap.start(into: ring)
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: spatializer.engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(reason: "The output device changed. Turn Spatialize on again.") }
            }
            statsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.logStats() }
            }
            let state = try spatializer.mixerState()
            profileInUse = state.usingPersonalizedHRTF
            isOn = true
            logger.notice("started at \(format.mSampleRate) Hz, mixer \(String(describing: state), privacy: .public)")
        } catch {
            stop(reason: error.localizedDescription)
        }
    }

    /// Tap goes first so Spotify is never muted with nothing playing.
    private func stop(reason: String?) {
        logStats()
        var messages = reason.map { [$0] } ?? []
        do { try tap?.stop() } catch { messages.append(error.localizedDescription) }
        spatializer?.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        statsTimer?.invalidate()
        tap = nil; spatializer = nil; ring = nil; configObserver = nil; statsTimer = nil
        isOn = false
        error = messages.isEmpty ? nil : messages.joined(separator: "\n")
        if let error { logger.error("stopped: \(error, privacy: .public)") } else { logger.notice("stopped") }
    }

    private func logStats() {
        guard let stats = ring?.stats else { return }
        logger.notice("underruns=\(stats.underruns) overruns=\(stats.overruns)")
    }
}
