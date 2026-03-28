import SwiftUI

@available(macOS 14.2, *)
@main
struct VibeFaderApp: App {
    @StateObject private var audioManager = AudioManager()

    var body: some Scene {
        MenuBarExtra {
            VolumePopoverView()
                .environmentObject(audioManager)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
