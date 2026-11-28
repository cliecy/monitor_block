import Darwin
import Foundation
import IOKit

public protocol DDCBackend: AnyObject {
    var isAvailable: Bool { get }
    func listEndpoints() -> [DDCDisplayEndpoint]
    func probeCapabilities(endpointIndex: Int) -> DDCCapabilities
    func readBrightness(endpointIndex: Int) -> Int?
    func setBrightness(_ brightness: Int, endpointIndex: Int) -> Bool
    func readVolume(endpointIndex: Int) -> Int?
    func setVolume(_ volume: Int, endpointIndex: Int) -> Bool
    func setMuted(_ muted: Bool, endpointIndex: Int) -> Bool
    func readInputSource(endpointIndex: Int, hint: DDCDisplayHint) -> DDCInputReadResult
    func writeRawInputCode(_ code: DDCInputCode, endpointIndex: Int) -> Bool
    func setInputSource(
        _ source: DisplayInputSource,
        endpointIndex: Int,
        protocolMode: InputSourceProtocolMode,
        hint: DDCDisplayHint
    ) -> Bool
}

public extension DDCBackend {
    func readInputSource(endpointIndex: Int) -> DDCInputReadResult {
        readInputSource(endpointIndex: endpointIndex, hint: DDCDisplayHint())
    }

    func setInputSource(
        _ source: DisplayInputSource,
        endpointIndex: Int,
        protocolMode: InputSourceProtocolMode
    ) -> Bool {
        setInputSource(source, endpointIndex: endpointIndex, protocolMode: protocolMode, hint: DDCDisplayHint())
    }
}

private typealias IOAVServiceCreateWithServiceFunc = @convention(c) (
    CFAllocator?,
    io_service_t
) -> Unmanaged<CFTypeRef>?

private typealias IOAVServiceWriteI2CFunc = @convention(c) (
    CFTypeRef,
    UInt32,
    UInt32,
    UnsafeMutableRawPointer,
    UInt32
) -> IOReturn

private typealias IOAVServiceReadI2CFunc = @convention(c) (
    CFTypeRef,
    UInt32,
    UInt32,
    UnsafeMutableRawPointer,
    UInt32
) -> IOReturn

/// Apple Silicon DDC/CI 控制器（基于 IOKit DCPAVServiceProxy + IOAVService I2C）
public final class AppleSiliconDDCBackend: DDCBackend {
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddressStandard: UInt32 = 0x51
    private static let dataAddressLGAlt: UInt32 = 0x50
    private static let vcpBrightness: UInt8 = 0x10
    private static let vcpInputSelectStandard: UInt8 = 0x60
    private static let vcpInputSelectLGAlt: UInt8 = 0xF4
    private static let vcpAudioVolume: UInt8 = 0x62
    private static let vcpAudioMute: UInt8 = 0x8D

    private let createWithService: IOAVServiceCreateWithServiceFunc?
    private let writeI2C: IOAVServiceWriteI2CFunc?
    private let readI2C: IOAVServiceReadI2CFunc?
    private let i2cLock = NSLock()
    private var handles: [UnsafeMutableRawPointer] = []

    public var isAvailable: Bool {
        createWithService != nil && writeI2C != nil
    }

    public init() {
        var loaded: [UnsafeMutableRawPointer] = []

        func load<T>(_ name: String, as type: T.Type) -> T? {
            let paths = [
                "/System/Library/Frameworks/IOKit.framework/IOKit"
            ]
            for path in paths {
                if let handle = dlopen(path, RTLD_LAZY) {
                    loaded.append(handle)
                    if let sym = dlsym(handle, name) {
                        return unsafeBitCast(sym, to: type)
                    }
                }
            }
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(sym, to: type)
            }
            return nil
        }

        self.createWithService = load("IOAVServiceCreateWithService", as: IOAVServiceCreateWithServiceFunc.self)
        self.writeI2C = load("IOAVServiceWriteI2C", as: IOAVServiceWriteI2CFunc.self)
        self.readI2C = load("IOAVServiceReadI2C", as: IOAVServiceReadI2CFunc.self)
        self.handles = loaded
    }

    deinit {
        for handle in handles {
            dlclose(handle)
        }
    }

    public func listEndpoints() -> [DDCDisplayEndpoint] {
        let services = discoverExternalAVServices()
        return services.enumerated().map { idx, item in
            DDCDisplayEndpoint(
                index: idx,
                name: item.name,
                serialNumber: item.serialNumber,
                numericSerial: item.numericSerial,
                registryPath: item.registryPath
            )
        }
    }

    public func probeCapabilities(endpointIndex: Int) -> DDCCapabilities {
        i2cLock.lock()
        defer { i2cLock.unlock() }

        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else {
            return .unreachable
        }
        let service = services[endpointIndex].service

        // 第 1 步：快速测试 I2C 是否可达（读亮度 0x10，首次若遇转接头刚唤醒暂忙则间隔 80ms 重试一次，再测音量 0x62）
        var lastWriteStatus: IOReturn = kIOReturnSuccess
        var brightnessProbe = readVCPPercentage(code: Self.vcpBrightness, service: service, outWriteStatus: &lastWriteStatus)
        if brightnessProbe == nil {
            usleep(80_000)
            brightnessProbe = readVCPPercentage(code: Self.vcpBrightness, service: service, outWriteStatus: &lastWriteStatus)
        }
        let volumeProbe = (brightnessProbe == nil)
            ? readVCPPercentage(code: Self.vcpAudioVolume, service: service, outWriteStatus: &lastWriteStatus)
            : nil

        guard brightnessProbe != nil || volumeProbe != nil else {
            if lastWriteStatus != kIOReturnSuccess {
                return .adapterBlocked
            }
            return .unreachable
        }

        // 第 2 步：读取完整 MCCS Capabilities (0xF3) 字符串
        if let rawCap = readCapabilitiesString(service: service),
           let parsed = DDCCapabilities.parse(capabilitiesString: rawCap) {
            return parsed
        }

        // 第 3 步：部分显示器（如部分 LG 机型）不完整返回 0xF3，按实际读值能力回退
        let volReachable = (volumeProbe != nil) || (readVCPPercentage(code: Self.vcpAudioVolume, service: service) != nil)
        return DDCCapabilities(
            isReachable: true,
            supportsBrightness: brightnessProbe != nil,
            supportsVolume: volReachable,
            supportedInputs: nil,
            rawCapabilitiesString: nil
        )
    }

    public func readBrightness(endpointIndex: Int) -> Int? {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else { return nil }
        return readVCPPercentage(code: Self.vcpBrightness, service: services[endpointIndex].service)
    }

    public func setBrightness(_ brightness: Int, endpointIndex: Int) -> Bool {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let clamped = UInt16(min(max(brightness, 0), 100))
        return writeVCP(
            code: Self.vcpBrightness,
            value: clamped,
            endpointIndex: endpointIndex,
            dataAddress: Self.dataAddressStandard
        )
    }

    public func readVolume(endpointIndex: Int) -> Int? {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else { return nil }
        return readVCPPercentage(code: Self.vcpAudioVolume, service: services[endpointIndex].service)
    }

    private func readVCPPercentage(
        code: UInt8,
        service: CFTypeRef,
        outWriteStatus: UnsafeMutablePointer<IOReturn>? = nil
    ) -> Int? {
        guard let writeI2C, let readI2C else { return nil }

        let checksum: UInt8 = 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ code
        var request: [UInt8] = [0x82, 0x01, code, checksum]

        let writeStatus = request.withUnsafeMutableBytes { buf -> IOReturn in
            guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
            return writeI2C(service, Self.chipAddress, Self.dataAddressStandard, ptr, UInt32(buf.count))
        }
        outWriteStatus?.pointee = writeStatus
        guard writeStatus == kIOReturnSuccess else { return nil }

        usleep(40_000)

        var reply = [UInt8](repeating: 0, count: 12)
        let readStatus = reply.withUnsafeMutableBytes { buf -> IOReturn in
            guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
            return readI2C(service, Self.chipAddress, Self.dataAddressStandard, ptr, UInt32(buf.count))
        }
        guard readStatus == kIOReturnSuccess else { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }

        let maxValue = (Int(reply[6]) << 8) | Int(reply[7])
        let currentValue = (Int(reply[8]) << 8) | Int(reply[9])
        guard maxValue > 0 else { return min(max(currentValue, 0), 100) }
        return min(max(Int((Double(currentValue) / Double(maxValue) * 100.0).rounded()), 0), 100)
    }

    private func readCapabilitiesString(service: CFTypeRef) -> String? {
        guard let writeI2C, let readI2C else { return nil }
        var full = Data()
        var offset: UInt16 = 0

        for _ in 0..<24 {
            let hi = UInt8((offset >> 8) & 0xFF)
            let lo = UInt8(offset & 0xFF)
            let checksum: UInt8 = 0x6E ^ 0x51 ^ 0x83 ^ 0xF3 ^ hi ^ lo
            var request: [UInt8] = [0x83, 0xF3, hi, lo, checksum]

            let wkr = request.withUnsafeMutableBytes { buf -> IOReturn in
                guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
                return writeI2C(service, Self.chipAddress, Self.dataAddressStandard, ptr, UInt32(buf.count))
            }
            guard wkr == kIOReturnSuccess else { break }

            usleep(55_000)

            var reply = [UInt8](repeating: 0, count: 38)
            let rkr = reply.withUnsafeMutableBytes { buf -> IOReturn in
                guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
                return readI2C(service, Self.chipAddress, Self.dataAddressStandard, ptr, UInt32(buf.count))
            }
            guard rkr == kIOReturnSuccess, reply[2] == 0xE3 else { break }

            let lenByte = Int(reply[1] & 0x7F)
            let chunkLen = max(0, min(lenByte - 3, 32))
            if chunkLen == 0 { break }

            full.append(contentsOf: reply[5..<(5 + chunkLen)])
            offset += UInt16(chunkLen)
        }

        guard !full.isEmpty else { return nil }
        return String(data: full, encoding: .ascii)
    }

    public func setVolume(_ volume: Int, endpointIndex: Int) -> Bool {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let clamped = UInt16(min(max(volume, 0), 100))
        return writeVCP(
            code: Self.vcpAudioVolume,
            value: clamped,
            endpointIndex: endpointIndex,
            dataAddress: Self.dataAddressStandard
        )
    }

    public func setMuted(_ muted: Bool, endpointIndex: Int) -> Bool {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        // MCCS VCP 0x8D: 1 = Mute, 2 = Unmute
        let value: UInt16 = muted ? 1 : 2
        return writeVCP(
            code: Self.vcpAudioMute,
            value: value,
            endpointIndex: endpointIndex,
            dataAddress: Self.dataAddressStandard
        )
    }

    public func readInputSource(endpointIndex: Int, hint: DDCDisplayHint = DDCDisplayHint()) -> DDCInputReadResult {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else {
            return DDCInputReadResult()
        }
        let target = services[endpointIndex]
        let isLG = hint.isLG || target.name.lowercased().contains("lg")

        let stdRaw = readVCPRaw(
            code: Self.vcpInputSelectStandard,
            service: target.service,
            dataAddress: Self.dataAddressStandard
        )
        let stdVal = stdRaw.map { $0 & 0xFF }

        var lgVal: UInt16? = nil
        // LG 显示器（含 CoreGraphics 识别出的 0x1E6D LG 机型）或标准 0x60 返回 0x00 占位值时，尝试回读 0x50/0xF4
        if isLG || stdVal == 0 {
            usleep(25_000)
            let lgRaw = readVCPRaw(
                code: Self.vcpInputSelectLGAlt,
                service: target.service,
                dataAddress: Self.dataAddressLGAlt
            )
            if let mapped = lgRaw.map({ $0 & 0xFF }), mapped > 0 {
                lgVal = mapped
            }
        }

        return DDCInputReadResult(standardValue: stdVal, lgAltValue: lgVal)
    }

    public func writeRawInputCode(_ code: DDCInputCode, endpointIndex: Int) -> Bool {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else { return false }
        return writeVCP(
            code: code.vcpCode,
            value: code.value,
            service: services[endpointIndex].service,
            dataAddress: code.dataAddress
        )
    }

    public func setInputSource(
        _ source: DisplayInputSource,
        endpointIndex: Int,
        protocolMode: InputSourceProtocolMode = .auto,
        hint: DDCDisplayHint = DDCDisplayHint()
    ) -> Bool {
        i2cLock.lock()
        defer { i2cLock.unlock() }
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else { return false }
        let target = services[endpointIndex]

        let stdCodes = resolvedStandardCodes(for: source, hint: hint)

        switch protocolMode {
        case .standard:
            return sendCandidates(
                stdCodes,
                vcpCode: Self.vcpInputSelectStandard,
                dataAddress: Self.dataAddressStandard,
                service: target.service
            )

        case .lgAlt:
            return sendCandidates(
                source.lgAltCandidateCodes,
                vcpCode: Self.vcpInputSelectLGAlt,
                dataAddress: Self.dataAddressLGAlt,
                service: target.service
            )

        case .auto:
            let isLG = hint.isLG || target.name.lowercased().contains("lg")
            let hasExplicitMCCS60 = !(hint.capabilities?.supportedInputCodes.isEmpty ?? true)

            // 1. 明确为非 LG 品牌（如实验室 DELL 0x10AC、BenQ、ASUS 等）或 0xF3 明确声明了标准 60(...) 列表的非 LG 屏：
            //    100% 纯粹走标准 MCCS 0x51/0x60（且优先直发 0xF3 声明的精确单码，绝不向 DELL 误发 LG 私有 0x50/0xF4）
            if !isLG && (hint.isKnownNonLG || hasExplicitMCCS60) {
                return sendCandidates(
                    stdCodes,
                    vcpCode: Self.vcpInputSelectStandard,
                    dataAddress: Self.dataAddressStandard,
                    service: target.service
                )
            }

            // 2. LG 显示器（vendorID == 0x1E6D）或未知厂商：先读一次 0x60 判定固件形态
            let preStd = readVCPRaw(
                code: Self.vcpInputSelectStandard,
                service: target.service,
                dataAddress: Self.dataAddressStandard
            ).map { $0 & 0xFF }
            usleep(25_000)

            let stdIsDummy = (preStd == 0)

            if isLG || stdIsDummy {
                let altOK = sendCandidates(
                    source.lgAltCandidateCodes,
                    vcpCode: Self.vcpInputSelectLGAlt,
                    dataAddress: Self.dataAddressLGAlt,
                    service: target.service
                )
                if !altOK {
                    usleep(60_000)
                    return sendCandidates(
                        stdCodes,
                        vcpCode: Self.vcpInputSelectStandard,
                        dataAddress: Self.dataAddressStandard,
                        service: target.service
                    )
                }

                // 当 0x60 读出为 0x00 或无返回（典型仅支持 0xF4 的 LG 固件）时不再追加 0x60，防止冲掉正在进行的 0xF4 切换；
                // 仅当该 LG 屏真实返回了非零 0x60（如老款 DP 模式 LG）且等待后端口仍未变化时，才补发标准 0x60 兜底。
                if let pre = preStd, pre > 0, !stdCodes.contains(pre) {
                    usleep(280_000)
                    let postStd = readVCPRaw(
                        code: Self.vcpInputSelectStandard,
                        service: target.service,
                        dataAddress: Self.dataAddressStandard
                    ).map { $0 & 0xFF }
                    if postStd == pre {
                        usleep(30_000)
                        let stdOK = sendCandidates(
                            stdCodes,
                            vcpCode: Self.vcpInputSelectStandard,
                            dataAddress: Self.dataAddressStandard,
                            service: target.service
                        )
                        return altOK || stdOK
                    }
                }
                return true
            } else {
                let stdOK = sendCandidates(
                    stdCodes,
                    vcpCode: Self.vcpInputSelectStandard,
                    dataAddress: Self.dataAddressStandard,
                    service: target.service
                )
                if stdOK { return true }
                return sendCandidates(
                    source.lgAltCandidateCodes,
                    vcpCode: Self.vcpInputSelectLGAlt,
                    dataAddress: Self.dataAddressLGAlt,
                    service: target.service
                )
            }
        }
    }

    private func resolvedStandardCodes(for source: DisplayInputSource, hint: DDCDisplayHint) -> [UInt16] {
        if let exact = hint.capabilities?.supportedInputCodes[source] {
            return [exact]
        }
        return source.standardCandidateCodes
    }

    private func sendCandidates(
        _ values: [UInt16],
        vcpCode: UInt8,
        dataAddress: UInt32,
        service: CFTypeRef
    ) -> Bool {
        var anyOK = false
        for (idx, val) in values.enumerated() {
            if idx > 0 {
                usleep(120_000)
            }
            if writeVCP(code: vcpCode, value: val, service: service, dataAddress: dataAddress) {
                anyOK = true
            }
        }
        return anyOK
    }

    private func readVCPRaw(
        code: UInt8,
        service: CFTypeRef,
        dataAddress: UInt32
    ) -> UInt16? {
        guard let writeI2C, let readI2C else { return nil }

        let addrByte = UInt8(dataAddress & 0xFF)
        let checksum: UInt8 = 0x6E ^ addrByte ^ 0x82 ^ 0x01 ^ code
        var request: [UInt8] = [0x82, 0x01, code, checksum]

        let writeStatus = request.withUnsafeMutableBytes { buf -> IOReturn in
            guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
            return writeI2C(service, Self.chipAddress, dataAddress, ptr, UInt32(buf.count))
        }
        guard writeStatus == kIOReturnSuccess else { return nil }

        usleep(40_000)

        var reply = [UInt8](repeating: 0, count: 12)
        let readStatus = reply.withUnsafeMutableBytes { buf -> IOReturn in
            guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
            return readI2C(service, Self.chipAddress, dataAddress, ptr, UInt32(buf.count))
        }
        guard readStatus == kIOReturnSuccess else { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }

        return (UInt16(reply[8]) << 8) | UInt16(reply[9])
    }

    private func writeVCP(
        code: UInt8,
        value: UInt16,
        endpointIndex: Int,
        dataAddress: UInt32
    ) -> Bool {
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else { return false }
        return writeVCP(code: code, value: value, service: services[endpointIndex].service, dataAddress: dataAddress)
    }

    private func writeVCP(
        code: UInt8,
        value: UInt16,
        service: CFTypeRef,
        dataAddress: UInt32
    ) -> Bool {
        guard let writeI2C else { return false }

        let highByte = UInt8((value >> 8) & 0xFF)
        let lowByte = UInt8(value & 0xFF)
        let addrByte = UInt8(dataAddress & 0xFF)
        let checksum: UInt8 = 0x6E ^ addrByte ^ 0x84 ^ 0x03 ^ code ^ highByte ^ lowByte
        var packet: [UInt8] = [0x84, 0x03, code, highByte, lowByte, checksum]

        var succeeded = false
        for attempt in 0..<2 {
            let status = packet.withUnsafeMutableBytes { buf -> IOReturn in
                guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
                return writeI2C(service, Self.chipAddress, dataAddress, ptr, UInt32(buf.count))
            }
            if status == kIOReturnSuccess {
                succeeded = true
            }
            if attempt == 0 {
                usleep(10_000)
            }
        }
        return succeeded
    }

    private struct ResolvedAVService {
        let service: CFTypeRef
        let name: String
        let serialNumber: String?
        let numericSerial: UInt32?
        let registryPath: String?
    }

    private func discoverExternalAVServices() -> [ResolvedAVService] {
        guard let createWithService else { return [] }

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [ResolvedAVService] = []
        var idx = 0

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            guard let locationProp = IORegistryEntryCreateCFProperty(
                entry,
                "Location" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String,
            locationProp == "External" else {
                continue
            }

            guard let avService = createWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else {
                continue
            }

            idx += 1
            let meta = resolveDisplayMetadata(from: entry)
            let name = meta.name ?? "外接显示器 #\(idx)"
            results.append(
                ResolvedAVService(
                    service: avService,
                    name: name,
                    serialNumber: meta.alphaSerial ?? meta.numericSerial.map { String($0) },
                    numericSerial: meta.numericSerial,
                    registryPath: resolveRegistryPath(for: entry)
                )
            )
        }

        return results
    }

    private func resolveRegistryPath(for entry: io_registry_entry_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 1024)
        let kr = IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuffer)
        guard kr == KERN_SUCCESS else { return nil }
        return String(cString: pathBuffer)
    }

    private func resolveDisplayMetadata(from entry: io_registry_entry_t) -> (name: String?, alphaSerial: String?, numericSerial: UInt32?) {
        var current = entry
        var shouldReleaseCurrent = false
        defer {
            if shouldReleaseCurrent {
                IOObjectRelease(current)
            }
        }

        for _ in 0..<6 {
            if let attrs = IORegistryEntryCreateCFProperty(
                current,
                "DisplayAttributes" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
            let productAttrs = attrs["ProductAttributes"] as? [String: Any] {
                let productName = (productAttrs["ProductName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let alphaSerial = (productAttrs["AlphanumericSerialNumber"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let numericSerial = (productAttrs["SerialNumber"] as? NSNumber).flatMap { $0.uint32Value != 0 ? $0.uint32Value : nil }
                if productName != nil || alphaSerial != nil || numericSerial != nil {
                    return (productName, alphaSerial, numericSerial)
                }
            }

            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if kr != KERN_SUCCESS || parent == 0 {
                break
            }
            if shouldReleaseCurrent {
                IOObjectRelease(current)
            }
            current = parent
            shouldReleaseCurrent = true
        }
        return (nil, nil, nil)
    }
}
