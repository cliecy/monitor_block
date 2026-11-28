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
    case software(deviceName: String)
    case unsupported

    public var badgeText: String? {
        switch self {
        case .coreAudio: return "系统音量"
        case .ddc: return "DDC/CI 硬件音量"
        case .software: return "软件音量"
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

/// 从显示器 MCCS Capabilities (0xF3) 或实时探测得到的硬件能力描述
public struct DDCCapabilities: Equatable, Sendable {
    public let isReachable: Bool
    /// 当 macOS DCP 驱动或 USB-C 转 HDMI 转换芯片（如 cHDMIb）在内核层直接拒绝 I2C 写入（0xE0114000）时为 true
    public let blockedByAdapterOrLink: Bool
    public let supportsBrightness: Bool
    public let supportsVolume: Bool
    /// 解析出的真实物理输入口；nil 表示未返回 0xF3 或未能解析，UI 回退展示全部常用输入源
    public let supportedInputs: [DisplayInputSource]?
    /// 从 0xF3 的 60(...) 中解析出的精确标准 VCP 0x60 硬件码（例如部分新款 Dell 将 USB-C 报为 0x19 而老款报为 0x1B）
    public let supportedInputCodes: [DisplayInputSource: UInt16]
    public let rawCapabilitiesString: String?

    public init(
        isReachable: Bool,
        blockedByAdapterOrLink: Bool = false,
        supportsBrightness: Bool,
        supportsVolume: Bool,
        supportedInputs: [DisplayInputSource]? = nil,
        supportedInputCodes: [DisplayInputSource: UInt16] = [:],
        rawCapabilitiesString: String? = nil
    ) {
        self.isReachable = isReachable
        self.blockedByAdapterOrLink = blockedByAdapterOrLink
        self.supportsBrightness = supportsBrightness
        self.supportsVolume = supportsVolume
        self.supportedInputs = supportedInputs
        self.supportedInputCodes = supportedInputCodes
        self.rawCapabilitiesString = rawCapabilitiesString
    }

    public static let unreachable = DDCCapabilities(
        isReachable: false,
        blockedByAdapterOrLink: false,
        supportsBrightness: false,
        supportsVolume: false,
        supportedInputs: [],
        rawCapabilitiesString: nil
    )

    public static let adapterBlocked = DDCCapabilities(
        isReachable: false,
        blockedByAdapterOrLink: true,
        supportsBrightness: false,
        supportsVolume: false,
        supportedInputs: [],
        rawCapabilitiesString: nil
    )

    /// 解析标准 MCCS Capabilities 字符串，例如：
    /// `(prot(monitor)type(lcd)model(U2718Q)...vcp(10 12 60(11 0F 10) D6)...)`
    public static func parse(capabilitiesString raw: String) -> DDCCapabilities? {
        guard let vcpBody = extractSection(named: "vcp", from: raw) else {
            return nil
        }

        // 遍历 vcp(...) 顶层 token 及其附带子括号
        var topCodes = Set<UInt8>()
        var inputValues: [UInt16] = []

        var i = vcpBody.startIndex
        let end = vcpBody.endIndex
        var lastCode: UInt8?

        while i < end {
            let ch = vcpBody[i]
            if ch.isWhitespace {
                i = vcpBody.index(after: i)
                continue
            }
            if ch == "(" {
                // 提取配对子括号内容
                var depth = 0
                let contentStart = vcpBody.index(after: i)
                var j = i
                while j < end {
                    if vcpBody[j] == "(" { depth += 1 }
                    else if vcpBody[j] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j = vcpBody.index(after: j)
                }
                if j < end, lastCode == 0x60 {
                    let sub = String(vcpBody[contentStart..<j])
                    let tokens = sub.split(whereSeparator: { $0.isWhitespace })
                    for tok in tokens {
                        if let val = UInt16(tok, radix: 16) {
                            inputValues.append(val)
                        }
                    }
                }
                i = (j < end) ? vcpBody.index(after: j) : end
                continue
            }

            // 读取 hex token
            var j = i
            while j < end && !vcpBody[j].isWhitespace && vcpBody[j] != "(" && vcpBody[j] != ")" {
                j = vcpBody.index(after: j)
            }
            let token = String(vcpBody[i..<j])
            if let code = UInt8(token, radix: 16) {
                topCodes.insert(code)
                lastCode = code
            } else {
                lastCode = nil
            }
            i = j
        }

        guard !topCodes.isEmpty else { return nil }

        var parsedInputs: [DisplayInputSource]? = nil
        var parsedInputCodes: [DisplayInputSource: UInt16] = [:]
        if !inputValues.isEmpty {
            var mapped: [DisplayInputSource] = []
            for val in inputValues {
                let low = val & 0xFF
                let candidate: DisplayInputSource?
                switch low {
                case 0x11: candidate = .hdmi1
                case 0x12: candidate = .hdmi2
                case 0x0F: candidate = .displayPort1
                case 0x10: candidate = .displayPort2
                case 0x1B, 0x19, 0x1F: candidate = .usbC
                default: candidate = nil
                }
                if let candidate {
                    if !mapped.contains(candidate) {
                        mapped.append(candidate)
                    }
                    if parsedInputCodes[candidate] == nil {
                        parsedInputCodes[candidate] = low
                    }
                }
            }
            if !mapped.isEmpty {
                parsedInputs = mapped
            }
        }

        return DDCCapabilities(
            isReachable: true,
            supportsBrightness: topCodes.contains(0x10),
            supportsVolume: topCodes.contains(0x62),
            supportedInputs: parsedInputs,
            supportedInputCodes: parsedInputCodes,
            rawCapabilitiesString: raw
        )
    }

    private static func extractSection(named name: String, from raw: String) -> String? {
        let lowered = raw.lowercased()
        let needle = "\(name.lowercased())("
        guard let range = lowered.range(of: needle) else { return nil }
        let start = range.upperBound
        var depth = 1
        var idx = start
        while idx < raw.endIndex {
            let c = raw[idx]
            if c == "(" { depth += 1 }
            else if c == ")" {
                depth -= 1
                if depth == 0 {
                    return String(raw[start..<idx])
                }
            }
            idx = raw.index(after: idx)
        }
        return nil
    }
}

public struct DDCDisplayEndpoint: Equatable, Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let serialNumber: String?
    public let numericSerial: UInt32?
    public let registryPath: String?
    public let currentVolume: Int?
    public let currentBrightness: Int?
    public let isMuted: Bool
    public let capabilities: DDCCapabilities?

    public var displayPortToken: String? {
        guard let registryPath else { return nil }
        let lowered = registryPath.lowercased()
        if let range = lowered.range(of: #"dispext\d+"#, options: .regularExpression) {
            return String(lowered[range])
        }
        return nil
    }

    public var storageKey: String {
        if let serialNumber, !serialNumber.isEmpty {
            return "serial:\(serialNumber)"
        }
        if let numericSerial, numericSerial != 0 {
            return "numserial:\(numericSerial)"
        }
        if let token = displayPortToken {
            return "port:\(token)"
        }
        if let registryPath, !registryPath.isEmpty {
            return "path:\(registryPath)"
        }
        return "endpoint:\(index):\(name)"
    }

    public init(
        index: Int,
        name: String,
        serialNumber: String? = nil,
        numericSerial: UInt32? = nil,
        registryPath: String? = nil,
        currentVolume: Int? = nil,
        currentBrightness: Int? = nil,
        isMuted: Bool = false,
        capabilities: DDCCapabilities? = nil
    ) {
        self.index = index
        self.name = name
        self.serialNumber = serialNumber
        self.numericSerial = numericSerial
        self.registryPath = registryPath
        self.currentVolume = currentVolume
        self.currentBrightness = currentBrightness
        self.isMuted = isMuted
        self.capabilities = capabilities
    }
}

/// 来自 CoreGraphics / CoreDisplay 的显示器硬件身份提示（弥补 Apple Silicon DCPAVServiceProxy 缺少厂商/型号属性的问题）
public struct DDCDisplayHint: Equatable, Sendable {
    public static let lgVendorID: UInt32 = 0x1E6D // 7789 (LG Electronics / GSM)

    public let vendorID: UInt32?
    public let modelID: UInt32?
    public let systemName: String?
    public let capabilities: DDCCapabilities?

    public init(
        vendorID: UInt32? = nil,
        modelID: UInt32? = nil,
        systemName: String? = nil,
        capabilities: DDCCapabilities? = nil
    ) {
        self.vendorID = vendorID
        self.modelID = modelID
        self.systemName = systemName
        self.capabilities = capabilities
    }

    public init(display: DisplayInfo, capabilities: DDCCapabilities? = nil) {
        self.vendorID = display.vendorID
        self.modelID = display.modelID
        self.systemName = display.systemName
        self.capabilities = capabilities
    }

    public var isLG: Bool {
        if vendorID == Self.lgVendorID {
            return true
        }
        if let systemName, systemName.lowercased().contains("lg") {
            return true
        }
        return false
    }

    /// 明确已知为非 LG 品牌（如 DELL 0x10AC、EIZO 0x15C3 等），严禁向其误发 LG 私有 0x50/0xF4 指令
    public var isKnownNonLG: Bool {
        if isLG { return false }
        if let vendorID, vendorID != 0 {
            return true
        }
        return false
    }
}

/// 单个信号源对应的精确硬件 DDC 编码（支持用户按真实硬件回读值一键校准或手动指定）
public struct DDCInputCode: Codable, Equatable, Sendable {
    public let dataAddress: UInt32
    public let vcpCode: UInt8
    public let value: UInt16

    public init(dataAddress: UInt32, vcpCode: UInt8, value: UInt16) {
        self.dataAddress = dataAddress
        self.vcpCode = vcpCode
        self.value = value
    }

    public var hexSummary: String {
        let proto = (vcpCode == 0xF4 || dataAddress == 0x50) ? "LG 0xF4" : "0x60"
        return String(format: "%@=0x%02X", proto, value)
    }

    /// 供「0xF4 只写不回读」的显示器（如部分 LG UltraFine HDMI 通道）手动绑定常用硬件编码
    public static func commonPresets(for source: DisplayInputSource) -> [(label: String, code: DDCInputCode)] {
        switch source {
        case .hdmi1:
            return [
                ("LG 专有 0xF4 = 0x90 (144)", DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: 0x90)),
                ("标准 0x60 = 0x11 (17)", DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: 0x11))
            ]
        case .hdmi2:
            return [
                ("LG 专有 0xF4 = 0x91 (145)", DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: 0x91)),
                ("标准 0x60 = 0x12 (18)", DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: 0x12))
            ]
        case .displayPort1:
            return [
                ("LG 专有 0xF4 = 0xD0 (208)", DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: 0xD0)),
                ("标准 0x60 = 0x0F (15)", DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: 0x0F))
            ]
        case .displayPort2:
            return [
                ("LG 专有 0xF4 = 0xD1 (209)", DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: 0xD1)),
                ("标准 0x60 = 0x10 (16)", DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: 0x10))
            ]
        case .usbC:
            return [
                ("LG 专有 0xF4 = 0xD1 (209 · 单 DP 机型)", DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: 0xD1)),
                ("LG 专有 0xF4 = 0xD2 (210 · 双 DP 机型)", DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: 0xD2)),
                ("标准 0x60 = 0x1B (27)", DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: 0x1B)),
                ("标准 0x60 = 0x19 (25)", DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: 0x19))
            ]
        }
    }
}

/// 从显示器硬件读取到的当前输入源原始编码
public struct DDCInputReadResult: Equatable, Sendable {
    public let standardValue: UInt16?
    public let lgAltValue: UInt16?

    public init(standardValue: UInt16? = nil, lgAltValue: UInt16? = nil) {
        self.standardValue = standardValue
        self.lgAltValue = lgAltValue
    }

    public var isEmpty: Bool {
        standardValue == nil && lgAltValue == nil
    }

    public var hasValidCode: Bool {
        (standardValue ?? 0) > 0 || (lgAltValue ?? 0) > 0
    }

    public var preferredCode: DDCInputCode? {
        // LG 专有 0xF4 读到高字节段（0x90/0x91/0xD0/0xD1/0xD2 等）时优先采用
        if let lg = lgAltValue, lg >= 0x80 {
            return DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: lg)
        }
        if let std = standardValue, std > 0 {
            return DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: std)
        }
        if let lg = lgAltValue, lg > 0 {
            return DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: lg)
        }
        return nil
    }

    public var rawSummary: String {
        var parts: [String] = []
        if let std = standardValue {
            parts.append(String(format: "0x60=0x%02X", std))
        }
        if let lg = lgAltValue {
            parts.append(String(format: "0xF4=0x%02X", lg))
        }
        return parts.isEmpty ? "硬件未返回当前输入码" : parts.joined(separator: " · ")
    }
}

public struct DisplayInputStatus: Equatable, Sendable {
    public let activeSource: DisplayInputSource?
    public let rawRead: DDCInputReadResult
    public let calibratedCodes: [DisplayInputSource: DDCInputCode]

    public init(
        activeSource: DisplayInputSource?,
        rawRead: DDCInputReadResult,
        calibratedCodes: [DisplayInputSource: DDCInputCode] = [:]
    ) {
        self.activeSource = activeSource
        self.rawRead = rawRead
        self.calibratedCodes = calibratedCodes
    }
}

public enum InputSourceProtocolMode: String, CaseIterable, Codable, Identifiable, Equatable, Sendable {
    case auto
    case standard
    case lgAlt

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "自动 (标准+LG)"
        case .standard: return "标准 0x60"
        case .lgAlt: return "LG 0xF4"
        }
    }

    public var next: InputSourceProtocolMode {
        switch self {
        case .auto: return .standard
        case .standard: return .lgAlt
        case .lgAlt: return .auto
        }
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

    /// 标准 MCCS VCP 0x60 主编码
    public var standardCode: UInt16 {
        switch self {
        case .displayPort1: return 0x0F // 15
        case .displayPort2: return 0x10 // 16
        case .hdmi1: return 0x11        // 17
        case .hdmi2: return 0x12        // 18
        case .usbC: return 0x1B         // 27
        }
    }

    /// LG 专有 VCP 0xF4 (dataAddress 0x50) 主编码
    /// 多数带 1×DP + 2×HDMI + 1×USB-C 的 LG 4K/UltraFine 机型将 USB-C 映射在 0xD1，少数三口 DP/USB-C 机型在 0xD2
    public var lgAltCode: UInt16 {
        switch self {
        case .displayPort1: return 0xD0 // 208
        case .displayPort2: return 0xD1 // 209
        case .usbC: return 0xD1         // 209（多数 LG 机型 USB-C）
        case .hdmi1: return 0x90        // 144
        case .hdmi2: return 0x91        // 145
        }
    }

    /// LG 专有候选编码列表（USB-C 同时覆盖 0xD1 与 0xD2）
    public var lgAltCandidateCodes: [UInt16] {
        switch self {
        case .usbC: return [0xD1, 0xD2]
        default: return [lgAltCode]
        }
    }

    /// 标准 MCCS 0x60 候选编码列表（USB-C 同时覆盖 0x1B 与 0x19）
    public var standardCandidateCodes: [UInt16] {
        switch self {
        case .usbC: return [0x1B, 0x19]
        default: return [standardCode]
        }
    }

    /// 根据硬件读出的原始 VCP 值及用户校准表，反推出当前激活的输入源
    public static func resolve(
        from read: DDCInputReadResult,
        calibrated: [DisplayInputSource: DDCInputCode] = [:]
    ) -> DisplayInputSource? {
        // 1. 优先精准匹配用户校准过的硬件码
        for (source, code) in calibrated {
            if code.vcpCode == 0xF4 || code.dataAddress == 0x50 {
                if read.lgAltValue == code.value { return source }
            } else {
                if read.standardValue == code.value { return source }
            }
        }

        // 2. 匹配 LG 专有 0xF4 返回值
        if let lg = read.lgAltValue {
            switch lg {
            case 0x90: return .hdmi1
            case 0x91: return .hdmi2
            case 0xD0: return .displayPort1
            case 0xD1, 0xD2: return .usbC
            default: break
            }
        }

        // 3. 匹配标准 MCCS 0x60 返回值
        if let std = read.standardValue {
            switch std {
            case 0x11: return .hdmi1
            case 0x12: return .hdmi2
            case 0x0F: return .displayPort1
            case 0x10: return .displayPort2
            case 0x1B, 0x19, 0x1F, 0xD1, 0xD2: return .usbC
            default: break
            }
        }

        return nil
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
