import AppKit
import CoreAudio
import Foundation

struct AudioProcess: Identifiable, Hashable {
    let pid: pid_t
    let processObjectID: AudioObjectID
    let bundleIdentifier: String
    let name: String
    let icon: NSImage

    var id: pid_t { pid }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.pid == rhs.pid
    }
}

final class AudioProcessDiscovery: @unchecked Sendable {

    // Core Audio selectors for process tracking
    // 'prs#' - list of audio process object IDs
    private static let processObjectListSelector = AudioObjectPropertySelector(0x70727323)
    // 'ppid' - PID of an audio process object
    private static let processPIDSelector = AudioObjectPropertySelector(0x70706964)

    /// Discovers apps that currently have audio sessions via Core Audio's process object list.
    func discoverAudioProcesses() -> [AudioProcess] {
        let address = audioObjectPropertyAddress(selector: Self.processObjectListSelector)
        guard let processObjectIDs = try? getAudioPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            type: AudioObjectID.self
        ), !processObjectIDs.isEmpty else {
            return discoverViaRunningApps()
        }

        var results: [AudioProcess] = []
        let runningApps = NSWorkspace.shared.runningApplications

        for objectID in processObjectIDs {
            guard let pid: pid_t = try? getAudioPropertyData(
                objectID: objectID,
                address: audioObjectPropertyAddress(selector: Self.processPIDSelector),
                type: pid_t.self
            ) else { continue }

            // Skip our own process
            if pid == ProcessInfo.processInfo.processIdentifier { continue }

            // Match to running application for name and icon
            if let app = runningApps.first(where: { $0.processIdentifier == pid }),
               let name = app.localizedName {
                let icon = app.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
                let bundleID = app.bundleIdentifier ?? "pid-\(pid)"
                results.append(AudioProcess(
                    pid: pid,
                    processObjectID: objectID,
                    bundleIdentifier: bundleID,
                    name: name,
                    icon: icon
                ))
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look up the Core Audio process object ID for a given PID.
    func processObjectID(for pid: pid_t) -> AudioObjectID? {
        let address = audioObjectPropertyAddress(selector: Self.processObjectListSelector)
        guard let processObjectIDs = try? getAudioPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            type: AudioObjectID.self
        ) else { return nil }

        for objectID in processObjectIDs {
            if let objPID: pid_t = try? getAudioPropertyData(
                objectID: objectID,
                address: audioObjectPropertyAddress(selector: Self.processPIDSelector),
                type: pid_t.self
            ), objPID == pid {
                return objectID
            }
        }
        return nil
    }

    private func discoverViaRunningApps() -> [AudioProcess] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app -> AudioProcess? in
                guard let name = app.localizedName else { return nil }
                let icon = app.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
                return AudioProcess(
                    pid: app.processIdentifier,
                    processObjectID: kAudioObjectUnknown,
                    bundleIdentifier: app.bundleIdentifier ?? "pid-\(app.processIdentifier)",
                    name: name,
                    icon: icon
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
