import AppKit
import Foundation

/// Represents an app whose volume can be controlled. Value type — all state lives in AudioManager.
struct AudioApp: Identifiable, Hashable {
    let pid: pid_t
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    var volume: Float = 1.0
    var isMuted: Bool = false

    var id: pid_t { pid }

    var effectiveVolume: Float {
        isMuted ? 0.0 : volume
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.pid == rhs.pid
    }

    init(pid: pid_t, bundleIdentifier: String, name: String, icon: NSImage) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
    }

    init(from process: AudioProcess) {
        self.init(
            pid: process.pid,
            bundleIdentifier: process.bundleIdentifier,
            name: process.name,
            icon: process.icon
        )
    }
}
