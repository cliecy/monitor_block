import Darwin
import Foundation
import IOKit

public protocol DDCBackend: AnyObject {
    var isAvailable: Bool { get }
    func listEndpoints() -> [DDCDisplayEndpoint]
    func readVolume(endpointIndex: Int) -> Int?
    func setVolume(_ volume: Int, endpointIndex: Int) -> Bool
    func setMuted(_ muted: Bool, endpointIndex: Int) -> Bool
    func readInputSource(endpointIndex: Int) -> DDCInputReadResult
    func writeRawInputCode(_ code: DDCInputCode, endpointIndex: Int) -> Bool
    func setInputSource(
        _ source: DisplayInputSource,
        endpointIndex: Int,
        protocolMode: InputSourceProtocolMode
    ) -> Bool
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
    private static let vcpInputSelectStandard: UInt8 = 0x60
    private static let vcpInputSelectLGAlt: UInt8 = 0xF4
    private static let vcpAudioVolume: UInt8 = 0x62
    private static let vcpAudioMute: UInt8 = 0x8D

    private let createWithService: IOAVServiceCreateWithServiceFunc?
    private let writeI2C: IOAVServiceWriteI2CFunc?
    private let readI2C: IOAVServiceReadI2CFunc?
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
                registryPath: item.registryPath
            )
        }
    }

    public func readVolume(endpointIndex: Int) -> Int? {
        guard let writeI2C, let readI2C else { return nil }
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else { return nil }
        let service = services[endpointIndex].service

        // Get VCP Feature: [0x82, 0x01, vcp, checksum]
        let vcp = Self.vcpAudioVolume
        let checksum: UInt8 = 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ vcp
        var request: [UInt8] = [0x82, 0x01, vcp, checksum]

        let writeStatus = request.withUnsafeMutableBytes { buf -> IOReturn in
            guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
            return writeI2C(service, Self.chipAddress, Self.dataAddressStandard, ptr, UInt32(buf.count))
        }
        guard writeStatus == kIOReturnSuccess else { return nil }

        usleep(40_000)

        var reply = [UInt8](repeating: 0, count: 12)
        let readStatus = reply.withUnsafeMutableBytes { buf -> IOReturn in
            guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
            return readI2C(service, Self.chipAddress, Self.dataAddressStandard, ptr, UInt32(buf.count))
        }
        guard readStatus == kIOReturnSuccess else { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { return nil }

        let maxValue = (Int(reply[6]) << 8) | Int(reply[7])
        let currentValue = (Int(reply[8]) << 8) | Int(reply[9])
        guard maxValue > 0 else { return min(max(currentValue, 0), 100) }
        return min(max(Int((Double(currentValue) / Double(maxValue) * 100.0).rounded()), 0), 100)
    }

    public func setVolume(_ volume: Int, endpointIndex: Int) -> Bool {
        let clamped = UInt16(min(max(volume, 0), 100))
        return writeVCP(
            code: Self.vcpAudioVolume,
            value: clamped,
            endpointIndex: endpointIndex,
            dataAddress: Self.dataAddressStandard
        )
    }

    public func setMuted(_ muted: Bool, endpointIndex: Int) -> Bool {
        // MCCS VCP 0x8D: 1 = Mute, 2 = Unmute
        let value: UInt16 = muted ? 1 : 2
        return writeVCP(
            code: Self.vcpAudioMute,
            value: value,
            endpointIndex: endpointIndex,
            dataAddress: Self.dataAddressStandard
        )
    }

    public func readInputSource(endpointIndex: Int) -> DDCInputReadResult {
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else {
            return DDCInputReadResult()
        }
        let target = services[endpointIndex]
        let isLG = target.name.lowercased().contains("lg")

        let stdRaw = readVCPRaw(
            code: Self.vcpInputSelectStandard,
            service: target.service,
            dataAddress: Self.dataAddressStandard
        )
        let stdVal = stdRaw.map { $0 & 0xFF }

        var lgVal: UInt16? = nil
        if isLG {
            usleep(20_000)
            let lgRaw = readVCPRaw(
                code: Self.vcpInputSelectLGAlt,
                service: target.service,
                dataAddress: Self.dataAddressLGAlt
            )
            lgVal = lgRaw.map { $0 & 0xFF }
        }

        return DDCInputReadResult(standardValue: stdVal, lgAltValue: lgVal)
    }

    public func writeRawInputCode(_ code: DDCInputCode, endpointIndex: Int) -> Bool {
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
        protocolMode: InputSourceProtocolMode = .auto
    ) -> Bool {
        let services = discoverExternalAVServices()
        guard services.indices.contains(endpointIndex) else { return false }
        let target = services[endpointIndex]

        switch protocolMode {
        case .standard:
            return sendCandidates(
                source.standardCandidateCodes,
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
            let isLG = target.name.lowercased().contains("lg")
            if isLG {
                // 对 LG 先发专有 0x50/0xF4 候选码（USB-C 会依次发 0xD1、0xD2），间隔足够时间后再补标准 0x51/0x60
                let altOK = sendCandidates(
                    source.lgAltCandidateCodes,
                    vcpCode: Self.vcpInputSelectLGAlt,
                    dataAddress: Self.dataAddressLGAlt,
                    service: target.service
                )
                usleep(60_000)
                let stdOK = sendCandidates(
                    source.standardCandidateCodes,
                    vcpCode: Self.vcpInputSelectStandard,
                    dataAddress: Self.dataAddressStandard,
                    service: target.service
                )
                return altOK || stdOK
            } else {
                // 其他品牌优先标准 MCCS 0x60，失败时自动回退尝试 0x50/0xF4
                let stdOK = sendCandidates(
                    source.standardCandidateCodes,
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

    private func sendCandidates(
        _ values: [UInt16],
        vcpCode: UInt8,
        dataAddress: UInt32,
        service: CFTypeRef
    ) -> Bool {
        var anyOK = false
        for (idx, val) in values.enumerated() {
            if idx > 0 {
                usleep(60_000)
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
                    serialNumber: meta.serial,
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

    private func resolveDisplayMetadata(from entry: io_registry_entry_t) -> (name: String?, serial: String?) {
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
                let numSerial = (productAttrs["SerialNumber"] as? NSNumber)?.stringValue
                if productName != nil || alphaSerial != nil || numSerial != nil {
                    return (productName, alphaSerial ?? numSerial)
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
        return (nil, nil)
    }
}
