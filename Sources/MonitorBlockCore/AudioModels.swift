import Foundation

public enum AudioTransportType: String, Equatable, Sendable {
    case builtIn
    case hdmi
    case displayPort
    case usb
    case bluetooth
    case airPlay
    case virtual
    case other

    public var symbolName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .hdmi, .displayPort: return "display"
        case .usb: return "cable.connector"
        case .bluetooth: return "headphones"
        case .airPlay: return "airplayaudio"
        case .virtual: return "waveform"
        case .other: return "hifispeaker"
        }
    }

    public var isExternalDisplayAudio: Bool {
        self == .hdmi || self == .displayPort
    }
}

public enum VolumeControlMode: Equatable, Sendable {
    case coreAudio
    case ddc(ddcIndex: Int, displayName: String)
    case unsupported

    public var badgeText: String? {
        switch self {
        case .coreAudio: return "系统音量"
        case .ddc: return "DDC/CI 硬件音量"
        case .unsupported: return "不支持音量调节"
        }
    }
}

public struct AudioOutputDevice: Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let transport: AudioTransportType
    public let isDefault: Bool
    public let supportsCoreAudioVolume: Bool

    public init(
        id: UInt32,
        uid: String,
        name: String,
        transport: AudioTransportType,
        isDefault: Bool,
        supportsCoreAudioVolume: Bool
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.isDefault = isDefault
        self.supportsCoreAudioVolume = supportsCoreAudioVolume
    }
}

public struct DDCDisplayEndpoint: Equatable, Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let serialNumber: String?
    public let registryPath: String?
    public let currentVolume: Int?
    public let isMuted: Bool

    public init(
        index: Int,
        name: String,
        serialNumber: String? = nil,
        registryPath: String? = nil,
        currentVolume: Int? = nil,
        isMuted: Bool = false
    ) {
        self.index = index
        self.name = name
        self.serialNumber = serialNumber
        self.registryPath = registryPath
        self.currentVolume = currentVolume
        self.isMuted = isMuted
    }
}

public enum DisplayInputSource: String, CaseIterable, Identifiable, Equatable, Sendable {
    case hdmi1
    case hdmi2
    case displayPort1
    case displayPort2
    case usbC

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .displayPort1: return "DP 1"
        case .displayPort2: return "DP 2"
        case .usbC: return "USB-C"
        }
    }

    /// 标准 MCCS VCP 0x60 输入源编码
    public var standardCode: UInt16 {
        switch self {
        case .displayPort1: return 0x0F // 15
        case .displayPort2: return 0x10 // 16
        case .hdmi1: return 0x11        // 17
        case .hdmi2: return 0x12        // 18
        case .usbC: return 0x1B         // 27
        }
    }

    /// LG 专有 VCP 0xF4 (dataAddress 0x50) 输入源编码
    public var lgAltCode: UInt16 {
        switch self {
        case .displayPort1: return 0xD0 // 208
        case .displayPort2: return 0xD1 // 209
        case .usbC: return 0xD2         // 210
        case .hdmi1: return 0x90        // 144
        case .hdmi2: return 0x91        // 145
        }
    }
}

public struct AudioVolumeSnapshot: Equatable, Sendable {
    public let deviceID: UInt32?
    public let deviceName: String?
    public let volume: Double // 0.0 ... 1.0
    public let isMuted: Bool
    public let mode: VolumeControlMode

    public init(
        deviceID: UInt32?,
        deviceName: String? = nil,
        volume: Double,
        isMuted: Bool,
        mode: VolumeControlMode
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.volume = min(max(volume, 0.0), 1.0)
        self.isMuted = isMuted
        self.mode = mode
    }
}
