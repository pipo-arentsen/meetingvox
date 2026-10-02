import CoreAudio
import Foundation

// MARK: - Core Audio device properties

/// Default-device lookup and descriptive properties, shared by the capture
/// recorder (default-input tracking) and `quill diag`.
enum CoreAudioDevice {
    static func defaultDevice(input: Bool) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static func describe(_ device: AudioObjectID) -> String {
        guard device != kAudioObjectUnknown else { return "none" }
        let rate = nominalSampleRate(device).map { String(format: "%.0f Hz", $0) } ?? "?"
        return "id=\(device) name=\"\(name(device) ?? "?")\" uid=\(uid(device) ?? "?") "
            + "rate=\(rate) transport=\(transport(device))"
    }

    static func name(_ device: AudioObjectID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    static func uid(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    static func transport(_ device: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return "?" }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "ContinuityCapture"
        case kAudioDeviceTransportTypeUnknown: return "Unknown"
        default: return String(format: "0x%08x", value)
        }
    }

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
