import CoreAudio
import SwiftUI

@available(macOS 14.2, *)
struct OutputDevicePicker: View {
    let devices: [AudioDevice]
    let selectedDeviceID: AudioObjectID
    let onSelect: (AudioObjectID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Picker("Output", selection: Binding(
                get: { selectedDeviceID },
                set: { onSelect($0) }
            )) {
                ForEach(devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
    }
}
