import AppKit
import Combine
import CoreAudio
import Foundation

/// Central coordinator for per-app volume control.
/// Controllers are created for all discovered apps but only start taps
/// when the user adjusts volume away from 100%.
@available(macOS 14.2, *)
@MainActor
final class AudioManager: ObservableObject {

    @Published var audioApps: [AudioApp] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    @Published var systemVolume: Float = 1.0

    private let discovery = AudioProcessDiscovery()
    private let deviceManager = AudioDeviceManager.shared
    private var controllers: [pid_t: AppAudioController] = [:]
    private var pollTimer: Timer?
    private var isRestarting = false // guard against re-entrant restarts

    init() {
        refreshDevices()
        refreshSystemVolume()
        refreshAudioApps()
        startMonitoring()
    }

    // MARK: - Public API

    /// Called on slider release — creates/destroys taps as needed.
    func commitVolume(for pid: pid_t, volume: Float) {
        guard let index = audioApps.firstIndex(where: { $0.pid == pid }) else { return }
        let clamped = min(max(volume, 0), 1)
        audioApps[index].volume = clamped
        applyAudioControl(at: index)
    }

    /// Called during slider drag — live volume update on running controllers only.
    func adjustVolumeLive(for pid: pid_t, volume: Float) {
        guard let controller = controllers[pid], controller.isRunning else { return }
        controller.setVolume(min(max(volume, 0), 1))
    }

    func toggleMute(for pid: pid_t) {
        guard let index = audioApps.firstIndex(where: { $0.pid == pid }) else { return }
        audioApps[index].isMuted.toggle()
        applyAudioControl(at: index)
    }

    func setSystemVolume(_ volume: Float) {
        systemVolume = volume
        try? deviceManager.setSystemVolume(volume)
    }

    func selectOutputDevice(_ deviceID: AudioObjectID) {
        selectedOutputDeviceID = deviceID
        try? deviceManager.setDefaultOutputDevice(deviceID)
    }

    func refreshAudioApps() {
        let processes = discovery.discoverAudioProcesses()
        let existingPIDs = Set(audioApps.map(\.pid))
        let newPIDs = Set(processes.map(\.pid))

        // Remove apps that are no longer running
        let removedPIDs = existingPIDs.subtracting(newPIDs)
        if !removedPIDs.isEmpty {
            for pid in removedPIDs {
                controllers[pid]?.stop()
                controllers.removeValue(forKey: pid)
            }
            audioApps.removeAll { removedPIDs.contains($0.pid) }
        }

        // Add new apps
        var didAdd = false
        for process in processes where !existingPIDs.contains(process.pid) {
            audioApps.append(AudioApp(from: process))
            didAdd = true
        }

        if didAdd {
            audioApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Private

    private func applyAudioControl(at index: Int) {
        let app = audioApps[index]
        let effective = app.effectiveVolume
        let needsControl = effective < 1.0 || app.isMuted

        if needsControl {
            ensureControllerRunning(for: app)
            controllers[app.pid]?.setVolume(effective)
        } else {
            // Back to 100% — remove the tap, let audio pass through natively
            controllers[app.pid]?.stop()
            controllers.removeValue(forKey: app.pid)
        }
    }

    private func ensureControllerRunning(for app: AudioApp) {
        if let existing = controllers[app.pid], existing.isRunning { return }

        controllers[app.pid]?.stop()

        let controller = AppAudioController(pid: app.pid)

        // System daemons have low-amplitude audio — use a softer volume curve
        let softCurveIDs: Set<String> = ["com.apple.avconferenced", "com.apple.callservicesd"]
        controller.useSoftCurve = softCurveIDs.contains(app.bundleIdentifier)

        controllers[app.pid] = controller

        do {
            try controller.start(outputDeviceID: selectedOutputDeviceID)
            controller.setVolume(app.effectiveVolume)
        } catch {
            print("[VibeFader] Failed to start controller for \(app.name): \(error)")
            controllers.removeValue(forKey: app.pid)
        }
    }

    private func startMonitoring() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioApps()
            }
        }

        try? deviceManager.onDeviceListChanged { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }

        try? deviceManager.onDefaultOutputDeviceChanged { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.refreshDevices()
                self.refreshSystemVolume()
                self.restartActiveControllers()
                self.listenForVolumeChanges()
            }
        }

        listenForVolumeChanges()
    }

    private func listenForVolumeChanges() {
        guard selectedOutputDeviceID != kAudioObjectUnknown else { return }
        try? deviceManager.onVolumeChanged(deviceID: selectedOutputDeviceID) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshSystemVolume()
            }
        }
    }

    private func restartActiveControllers() {
        // Guard against re-entrant calls (creating aggregates triggers device notifications)
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }

        let savedVolume = try? deviceManager.systemVolume()

        // Only restart controllers that are actually running (not all apps)
        for (pid, controller) in controllers where controller.isRunning {
            let vol = controller.volume
            controller.stop()
            let newController = AppAudioController(pid: pid)
            controllers[pid] = newController
            do {
                try newController.start(outputDeviceID: selectedOutputDeviceID)
                newController.setVolume(vol)
            } catch {
                controllers.removeValue(forKey: pid)
            }
        }

        if let savedVolume = savedVolume {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                try? self?.deviceManager.setSystemVolume(savedVolume)
                self?.systemVolume = savedVolume
            }
        }
    }

    private func refreshDevices() {
        outputDevices = (try? deviceManager.outputDevices()) ?? []
        selectedOutputDeviceID = (try? deviceManager.defaultOutputDeviceID()) ?? kAudioObjectUnknown
        outputDevices.removeAll { $0.uid.hasPrefix("com.chadon.vibefader.tap.") }
    }

    private func refreshSystemVolume() {
        systemVolume = (try? deviceManager.systemVolume()) ?? 1.0
    }
}
