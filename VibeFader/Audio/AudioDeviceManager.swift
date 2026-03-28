import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hasOutput: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }
}

final class AudioDeviceManager: @unchecked Sendable {
    static let shared = AudioDeviceManager()

    private init() {}

    // MARK: - Output Devices

    func outputDevices() throws -> [AudioDevice] {
        let deviceIDs = try getAudioPropertyArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: audioObjectPropertyAddress(selector: kAudioHardwarePropertyDevices),
            type: AudioObjectID.self
        )

        return deviceIDs.compactMap { deviceID in
            guard let device = try? makeAudioDevice(id: deviceID),
                  device.hasOutput else { return nil }
            return device
        }
    }

    func defaultOutputDevice() throws -> AudioDevice {
        let deviceID = try getAudioPropertyData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: audioObjectPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice),
            type: AudioObjectID.self
        )
        return try makeAudioDevice(id: deviceID)
    }

    func defaultOutputDeviceID() throws -> AudioObjectID {
        try getAudioPropertyData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: audioObjectPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice),
            type: AudioObjectID.self
        )
    }

    func setDefaultOutputDevice(_ deviceID: AudioObjectID) throws {
        try setAudioPropertyData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: audioObjectPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice),
            value: deviceID
        )
    }

    // MARK: - System Volume

    func systemVolume() throws -> Float32 {
        let deviceID = try defaultOutputDeviceID()
        return try getAudioPropertyData(
            objectID: deviceID,
            address: audioObjectPropertyAddress(
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput
            ),
            type: Float32.self
        )
    }

    func setSystemVolume(_ volume: Float32) throws {
        let deviceID = try defaultOutputDeviceID()
        try setAudioPropertyData(
            objectID: deviceID,
            address: audioObjectPropertyAddress(
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput
            ),
            value: volume
        )
    }

    // MARK: - Listeners

    func onDefaultOutputDeviceChanged(_ handler: @escaping @Sendable () -> Void) throws {
        try addAudioPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: audioObjectPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        ) { _, _ in
            handler()
        }
    }

    func onDeviceListChanged(_ handler: @escaping @Sendable () -> Void) throws {
        try addAudioPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: audioObjectPropertyAddress(selector: kAudioHardwarePropertyDevices)
        ) { _, _ in
            handler()
        }
    }

    // MARK: - Helpers

    private func makeAudioDevice(id: AudioObjectID) throws -> AudioDevice {
        let name = try getAudioPropertyString(
            objectID: id,
            address: audioObjectPropertyAddress(selector: kAudioObjectPropertyName)
        )

        let uid = try getAudioPropertyString(
            objectID: id,
            address: audioObjectPropertyAddress(selector: kAudioDevicePropertyDeviceUID)
        )

        let hasOutput = deviceHasOutputStreams(id)

        return AudioDevice(id: id, uid: uid, name: name, hasOutput: hasOutput)
    }

    private func deviceHasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        guard let streams = try? getAudioPropertyArray(
            objectID: deviceID,
            address: audioObjectPropertyAddress(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeOutput
            ),
            type: AudioObjectID.self
        ) else { return false }
        return !streams.isEmpty
    }
}
