import SwiftUI

@available(macOS 14.2, *)
struct AppVolumeRow: View {
    let app: AudioApp
    let onVolumeCommit: (Float) -> Void
    let onVolumeDrag: (Float) -> Void
    let onToggleMute: () -> Void

    @State private var sliderValue: Double
    @State private var isDragging = false

    init(app: AudioApp, onVolumeCommit: @escaping (Float) -> Void, onVolumeDrag: @escaping (Float) -> Void, onToggleMute: @escaping () -> Void) {
        self.app = app
        self.onVolumeCommit = onVolumeCommit
        self.onVolumeDrag = onVolumeDrag
        self.onToggleMute = onToggleMute
        self._sliderValue = State(initialValue: Double(app.volume))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .cornerRadius(5)

            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)

            Button(action: onToggleMute) {
                Image(systemName: muteIcon)
                    .font(.system(size: 11))
                    .foregroundColor(app.isMuted ? .red : .secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(app.isMuted ? "Unmute" : "Mute")

            Slider(value: $sliderValue, in: 0...1) { editing in
                isDragging = editing
                if !editing {
                    // Slider released — commit the volume (creates/destroys taps)
                    onVolumeCommit(Float(sliderValue))
                }
            }
            .frame(minWidth: 100)
            .disabled(app.isMuted)

            Text("\(Int(displayPercent))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onChange(of: sliderValue) { _, newValue in
            if isDragging {
                // Live update only if a controller is already running
                onVolumeDrag(Float(newValue))
            }
        }
        .onChange(of: app.volume) { _, newValue in
            // Sync from model (e.g. after unmute restores volume)
            if !isDragging {
                sliderValue = Double(newValue)
            }
        }
    }

    private var displayPercent: Double {
        if app.isMuted { return 0 }
        return sliderValue * 100
    }

    private var muteIcon: String {
        if app.isMuted { return "speaker.slash.fill" }
        let v = sliderValue
        switch v {
        case 0: return "speaker.slash.fill"
        case ..<0.33: return "speaker.wave.1.fill"
        case ..<0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
