import AppKit
import CoreAudio
import Darwin
import Foundation

struct AudioProcess: Identifiable, Hashable {
    let pid: pid_t
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
    // 'piro' - whether the process currently has active output IO
    private static let processIsRunningOutputSelector = AudioObjectPropertySelector(0x7069726F)
    private static let knownAudioDaemons: [String: (bundleID: String, displayName: String)] = [
        "avconferenced": ("com.apple.avconferenced", "avconferenced"),
        "callservicesd": ("com.apple.callservicesd", "callservicesd"),
    ]

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

            if pid == ProcessInfo.processInfo.processIdentifier { continue }

            if let process = audioProcess(for: pid, runningApps: runningApps) {
                results.append(process)
            }
        }

        return deduplicate(results)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
                    bundleIdentifier: app.bundleIdentifier ?? "pid-\(app.processIdentifier)",
                    name: name,
                    icon: icon
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func deduplicate(_ processes: [AudioProcess]) -> [AudioProcess] {
        var keyed: [String: AudioProcess] = [:]

        for process in processes {
            let key = "\(process.bundleIdentifier)|\(process.name)"
            guard let existing = keyed[key] else {
                keyed[key] = process
                continue
            }

            if shouldPrefer(process, over: existing) {
                keyed[key] = process
            }
        }

        return Array(keyed.values)
    }

    private func shouldPrefer(_ candidate: AudioProcess, over existing: AudioProcess) -> Bool {
        let candidateIsOutputting = isRunningOutput(pid: candidate.pid)
        let existingIsOutputting = isRunningOutput(pid: existing.pid)

        if candidateIsOutputting != existingIsOutputting {
            return candidateIsOutputting
        }

        return candidate.pid < existing.pid
    }

    private func audioProcess(for pid: pid_t, runningApps: [NSRunningApplication]) -> AudioProcess? {
        if let app = runningApps.first(where: { $0.processIdentifier == pid }),
           let name = app.localizedName {
            let icon = app.icon ?? fallbackIcon()
            let bundleID = app.bundleIdentifier ?? "pid-\(pid)"
            return AudioProcess(pid: pid, bundleIdentifier: bundleID, name: name, icon: icon)
        }

        if let bundledProcess = bundledProcess(for: pid) {
            return bundledProcess
        }

        if let daemonProcess = daemonProcess(for: pid) {
            return daemonProcess
        }

        guard let processName = processName(for: pid) else { return nil }
        return AudioProcess(
            pid: pid,
            bundleIdentifier: "pid-\(pid)",
            name: processName,
            icon: fallbackIcon()
        )
    }

    private func bundledProcess(for pid: pid_t) -> AudioProcess? {
        guard let executablePath = executablePath(for: pid),
              let appURL = containingAppURL(for: executablePath),
              let bundle = Bundle(url: appURL) else {
            return nil
        }

        let bundleID = bundle.bundleIdentifier ?? "pid-\(pid)"
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        return AudioProcess(pid: pid, bundleIdentifier: bundleID, name: name, icon: icon)
    }

    private func daemonProcess(for pid: pid_t) -> AudioProcess? {
        guard let processName = processName(for: pid),
              let daemon = Self.knownAudioDaemons[processName] else {
            return nil
        }

        return AudioProcess(
            pid: pid,
            bundleIdentifier: daemon.bundleID,
            name: daemon.displayName,
            icon: fallbackIcon()
        )
    }

    private func containingAppURL(for executablePath: String) -> URL? {
        let components = executablePath.split(separator: "/")
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }

        let appPath = "/" + components[...appIndex].joined(separator: "/")
        return URL(fileURLWithPath: appPath)
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func isRunningOutput(pid: pid_t) -> Bool {
        guard let objectID = processObjectID(for: pid),
              let isRunning: UInt32 = try? getAudioPropertyData(
                objectID: objectID,
                address: audioObjectPropertyAddress(selector: Self.processIsRunningOutputSelector),
                type: UInt32.self
              ) else {
            return false
        }

        return isRunning != 0
    }

    private func fallbackIcon() -> NSImage {
        NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
    }
}
