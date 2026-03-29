import CoreAudio
import Foundation

// MARK: - Property Address Helpers

func audioObjectPropertyAddress(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - Generic Property Getters

func getAudioPropertyData<T>(
    objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    type: T.Type
) throws -> T {
    var address = address
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { value.deallocate() }

    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value)
    guard status == kAudioHardwareNoError else {
        throw AudioError.propertyError(status)
    }
    return value.load(as: T.self)
}

func getAudioPropertyArray<T>(
    objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    type: T.Type
) throws -> [T] {
    var address = address
    var size: UInt32 = 0

    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == kAudioHardwareNoError else {
        throw AudioError.propertyError(status)
    }

    let count = Int(size) / MemoryLayout<T>.size
    guard count > 0 else { return [] }

    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }

    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    guard status == kAudioHardwareNoError else {
        throw AudioError.propertyError(status)
    }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

func getAudioPropertyString(
    objectID: AudioObjectID,
    address: AudioObjectPropertyAddress
) throws -> String {
    var address = address
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == kAudioHardwareNoError, let cfStr = value?.takeRetainedValue() else {
        throw AudioError.propertyError(status)
    }
    return cfStr as String
}

func setAudioPropertyData<T>(
    objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    value: T
) throws {
    var address = address
    var value = value
    let size = UInt32(MemoryLayout<T>.size)

    let status = AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &value)
    guard status == kAudioHardwareNoError else {
        throw AudioError.propertyError(status)
    }
}

// MARK: - Property Listener

func addAudioPropertyListener(
    objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    listener: @escaping AudioObjectPropertyListenerBlock
) throws {
    var address = address
    let status = AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, listener)
    guard status == kAudioHardwareNoError else {
        throw AudioError.propertyError(status)
    }
}


// MARK: - Error Type

enum AudioError: LocalizedError {
    case propertyError(OSStatus)
    case deviceNotFound
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .propertyError(let status):
            return "Core Audio error: \(status) (\(fourCharString(from: status)))"
        case .deviceNotFound:
            return "Audio device not found"
        case .tapCreationFailed(let status):
            return "Failed to create audio tap: \(status)"
        case .aggregateDeviceFailed(let status):
            return "Failed to create aggregate device: \(status)"
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        }
    }
}

private func fourCharString(from status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
    let chars = bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : Character(".") }
    return String(chars)
}
