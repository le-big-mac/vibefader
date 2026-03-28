import SwiftUI

@available(macOS 14.2, *)
struct VolumePopoverView: View {
    @EnvironmentObject var audioManager: AudioManager

    @State private var systemVolumeSlider: Double = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("VibeFader")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit VibeFader")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // System volume
            systemVolumeRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // App list
            if audioManager.audioApps.isEmpty {
                emptyState
            } else {
                appList
            }

            Divider()

            // Output device picker
            OutputDevicePicker(
                devices: audioManager.outputDevices,
                selectedDeviceID: audioManager.selectedOutputDeviceID,
                onSelect: { audioManager.selectOutputDevice($0) }
            )
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear {
            systemVolumeSlider = Double(audioManager.systemVolume)
        }
        .onChange(of: audioManager.systemVolume) { _, newValue in
            systemVolumeSlider = Double(newValue)
        }
    }

    // MARK: - Subviews

    private var systemVolumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: systemVolumeIcon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 24)

            Text("System")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 90, alignment: .leading)

            Spacer().frame(width: 16)

            Slider(value: $systemVolumeSlider, in: 0...1) { editing in
                if !editing {
                    audioManager.setSystemVolume(Float(systemVolumeSlider))
                }
            }

            Text("\(Int(systemVolumeSlider * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.badge.exclamationmark")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No audio apps detected")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Apps will appear here when they produce audio")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var appList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(audioManager.audioApps) { app in
                    AppVolumeRow(
                        app: app,
                        onVolumeCommit: { volume in
                            audioManager.commitVolume(for: app.pid, volume: volume)
                        },
                        onVolumeDrag: { volume in
                            audioManager.adjustVolumeLive(for: app.pid, volume: volume)
                        },
                        onToggleMute: {
                            audioManager.toggleMute(for: app.pid)
                        }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 300)
    }

    private var systemVolumeIcon: String {
        switch systemVolumeSlider {
        case 0: return "speaker.slash.fill"
        case ..<0.33: return "speaker.wave.1.fill"
        case ..<0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
