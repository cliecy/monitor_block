import AudioToolbox
import CoreAudio
import Foundation

public protocol AudioBackend: AnyObject {
    func listOutputDevices() -> [AudioOutputDevice]
    func defaultOutputDeviceID() -> UInt32?
    func setDefaultOutputDevice(id: UInt32) -> Bool
    func readCoreAudioVolume(deviceID: UInt32) -> Double?
    func setCoreAudioVolume(_ volume: Double, deviceID: UInt32) -> Bool
    func readCoreAudioMuted(deviceID: UInt32) -> Bool?
    func setCoreAudioMuted(_ muted: Bool, deviceID: UInt32) -> Bool
    func startObservingChanges(_ handler: @escaping @Sendable () -> Void)
    func stopObservingChanges()
}

public final class CoreAudioBackend: AudioBackend {
    private let listenerQueue = DispatchQueue(label: "local.cliecy.MonitorBlock.CoreAudioListener")
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {}

    deinit {
        stopObservingChanges()
    }

    public func listOutputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        let defaultID = defaultOutputDeviceID()

        return deviceIDs.compactMap { deviceID -> AudioOutputDevice? in
            guard hasOutputStreams(deviceID: deviceID) else { return nil }
            let uid = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
                ?? "audio-\(deviceID)"
            // 过滤本应用创建的私有软件音量聚合设备，避免出现在用户的输出设备列表中
            if uid.hasPrefix("local.cliecy.MonitorBlock.SoftVol.") {
                return nil
            }
            let name = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
                ?? "音频设备 #\(deviceID)"
            let transport = transportType(deviceID: deviceID)
            let supportsVolume = supportsCoreAudioVolumeControl(deviceID: deviceID)

            return AudioOutputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                transport: transport,
                isDefault: deviceID == defaultID,
                supportsCoreAudioVolume: supportsVolume
            )
        }
    }

    public func defaultOutputDeviceID() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    public func setDefaultOutputDevice(id: UInt32) -> Bool {
        var deviceID = AudioDeviceID(id)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            0,
            nil,
            size,
            &deviceID
        )

        // 同步切换系统提示音输出（如果允许）
        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress,
            0,
            nil,
            size,
            &deviceID
        )

        return status == noErr
    }

    public func readCoreAudioVolume(deviceID: UInt32) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                return Double(volume)
            }
        }

        // 回退到主通道或声道 1
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var scalarAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &scalarAddr) {
                var volume: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(deviceID, &scalarAddr, 0, nil, &size, &volume) == noErr {
                    return Double(volume)
                }
            }
        }
        return nil
    }

    public func setCoreAudioVolume(_ volume: Double, deviceID: UInt32) -> Bool {
        var clamped = Float32(min(max(volume, 0.0), 1.0))
        let size = UInt32(MemoryLayout<Float32>.size)

        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtualAddr), isPropertySettable(deviceID: deviceID, address: &virtualAddr) {
            if AudioObjectSetPropertyData(deviceID, &virtualAddr, 0, nil, size, &clamped) == noErr {
                return true
            }
        }

        var succeeded = false
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var scalarAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &scalarAddr), isPropertySettable(deviceID: deviceID, address: &scalarAddr) {
                if AudioObjectSetPropertyData(deviceID, &scalarAddr, 0, nil, size, &clamped) == noErr {
                    succeeded = true
                }
            }
        }
        return succeeded
    }

    public func readCoreAudioMuted(deviceID: UInt32) -> Bool? {
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &address) {
                var muted: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr {
                    return muted != 0
                }
            }
        }
        return nil
    }

    public func setCoreAudioMuted(_ muted: Bool, deviceID: UInt32) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var succeeded = false

        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &address), isPropertySettable(deviceID: deviceID, address: &address) {
                if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                    succeeded = true
                }
            }
        }
        return succeeded
    }

    public func startObservingChanges(_ handler: @escaping @Sendable () -> Void) {
        stopObservingChanges()

        let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let defaultBlock: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            listenerQueue,
            devicesBlock
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            listenerQueue,
            defaultBlock
        )

        devicesListenerBlock = devicesBlock
        defaultOutputListenerBlock = defaultBlock
    }

    public func stopObservingChanges() {
        if let block = devicesListenerBlock {
            var devicesAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddr,
                listenerQueue,
                block
            )
            devicesListenerBlock = nil
        }
        if let block = defaultOutputListenerBlock {
            var defaultAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddr,
                listenerQueue,
                block
            )
            defaultOutputListenerBlock = nil
        }
    }

    // MARK: - Private CoreAudio Helpers

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPtr) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    private func supportsCoreAudioVolumeControl(deviceID: AudioDeviceID) -> Bool {
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtualAddr), isPropertySettable(deviceID: deviceID, address: &virtualAddr) {
            return true
        }
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var scalarAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &scalarAddr), isPropertySettable(deviceID: deviceID, address: &scalarAddr) {
                return true
            }
        }
        return false
    }

    private func isPropertySettable(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    private func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let str = value?.takeRetainedValue() as String? else {
            return nil
        }
        return str
    }

    private func transportType(deviceID: AudioDeviceID) -> AudioTransportType {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return .other
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }
}

/// 统一管理音频输出切换、CoreAudio 音量、外接显示器 DDC/CI（亮度/音量/输入源/能力探测）与免驱动软件音量
public final class AudioManager: @unchecked Sendable {
    private let audioBackend: AudioBackend
    private let ddcBackend: DDCBackend
    private let softwareVolume: SoftwareVolumeBackend
    private let store: StateStoreProtocol
    private let lock = NSLock()
    private var cachedDDCVolumes: [String: Int] = [:]
    private var cachedDDCBrightness: [String: Int] = [:]
    private var cachedCapabilities: [String: DDCCapabilities] = [:]
    private var preMuteDDCVolumes: [String: Int] = [:]
    private var cachedDDCMuted: [String: Bool] = [:]
    private var preferredDDCEndpointByAudioUID: [String: Int]
    private var preferredDDCKeyByDisplayUUID: [String: String]
    private var calibratedInputCodes: [String: [String: DDCInputCode]]
    private var displayInputProtocols: [String: InputSourceProtocolMode]
    private var cachedInputStatuses: [String: DisplayInputStatus] = [:]
    private var knownDisplays: [DisplayInfo] = []
    private var savedSoftwareVolumes: [String: Double] = [:] // audioDevice.uid -> 0.0...1.0
    private var savedSoftwareMuted: [String: Bool] = [:]
    private var _isSoftwareVolumeEnabled: Bool = true

    public var isSoftwareVolumeSupported: Bool {
        softwareVolume.isSupported
    }

    public var isSoftwareVolumeActive: Bool {
        softwareVolume.isActive
    }

    public var isSoftwareVolumeEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSoftwareVolumeEnabled
        }
        set {
            lock.lock()
            _isSoftwareVolumeEnabled = newValue
            lock.unlock()
            if !newValue {
                softwareVolume.deactivate()
            }
        }
    }

    public var softwareVolumeLastError: String? {
        softwareVolume.lastError
    }

    public init(
        audioBackend: AudioBackend = CoreAudioBackend(),
        ddcBackend: DDCBackend = AppleSiliconDDCBackend(),
        softwareVolume: SoftwareVolumeBackend = CoreAudioProcessTapVolumeEngine(),
        store: StateStoreProtocol = FileStateStore()
    ) {
        self.audioBackend = audioBackend
        self.ddcBackend = ddcBackend
        self.softwareVolume = softwareVolume
        self.store = store
        let loaded = store.loadState()
        // 自动清洗旧版本可能残留的冲突音频绑定（例如两台外接音频同时指向同一个整数索引 1）
        var counts: [Int: Int] = [:]
        for idx in loaded.audioToDDCBindings.values {
            counts[idx, default: 0] += 1
        }
        self.preferredDDCEndpointByAudioUID = loaded.audioToDDCBindings.filter { counts[$0.value, default: 0] == 1 }
        self.preferredDDCKeyByDisplayUUID = loaded.displayToDDCBindings
        self.calibratedInputCodes = loaded.calibratedInputCodes
        self.displayInputProtocols = loaded.displayInputProtocols
    }

    public func stopSoftwareVolume() {
        softwareVolume.deactivate()
    }

    public func updateKnownDisplays(_ displays: [DisplayInfo]) {
        lock.lock()
        knownDisplays = displays
        lock.unlock()
    }

    public func listOutputDevices() -> [AudioOutputDevice] {
        audioBackend.listOutputDevices()
    }

    public func listDDCEndpoints() -> [DDCDisplayEndpoint] {
        let rawEndpoints = ddcBackend.listEndpoints()
        lock.lock()
        let displaysSnapshot = knownDisplays
        lock.unlock()
        let displayMapping: [String: Int] = displaysSnapshot.isEmpty
            ? [:]
            : matchAllDDCEndpoints(for: displaysSnapshot, endpoints: rawEndpoints)

        return rawEndpoints.map { endpoint in
            let matchedUUID = displayMapping.first(where: { $0.value == endpoint.index })?.key
            let primaryKey = matchedUUID.map { "uuid:\($0)" } ?? endpoint.storageKey

            lock.lock()
            let cachedVol = cachedDDCVolumes[primaryKey] ?? cachedDDCVolumes[endpoint.storageKey]
            let cachedBright = cachedDDCBrightness[primaryKey] ?? cachedDDCBrightness[endpoint.storageKey]
            let cachedMute = cachedDDCMuted[primaryKey] ?? cachedDDCMuted[endpoint.storageKey] ?? false
            let caps = cachedCapabilities[primaryKey]
                ?? (!endpoint.storageKey.hasPrefix("port:") ? cachedCapabilities[endpoint.storageKey] : nil)
            lock.unlock()

            return DDCDisplayEndpoint(
                index: endpoint.index,
                name: endpoint.name,
                serialNumber: endpoint.serialNumber,
                numericSerial: endpoint.numericSerial,
                registryPath: endpoint.registryPath,
                currentVolume: cachedVol,
                currentBrightness: cachedBright,
                isMuted: cachedMute,
                capabilities: caps
            )
        }
    }

    /// 探测并缓存某台外接屏的 MCCS Capabilities 与当前硬件亮度（建议在后台线程调用）
    @discardableResult
    public func probeCapabilitiesAndBrightness(
        endpointIndex: Int,
        displayUUID: String? = nil,
        force: Bool = false
    ) -> DDCCapabilities {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        guard ctx.endpoint != nil else {
            return .unreachable
        }

        lock.lock()
        let existing = cachedCapabilities[ctx.primaryKey]
        lock.unlock()

        let caps: DDCCapabilities
        if !force, let existing {
            caps = existing
        } else {
            caps = ddcBackend.probeCapabilities(endpointIndex: ctx.resolvedIndex)
            lock.lock()
            cachedCapabilities[ctx.primaryKey] = caps
            lock.unlock()
        }

        if caps.isReachable && caps.supportsBrightness,
           let brightness = ddcBackend.readBrightness(endpointIndex: ctx.resolvedIndex) {
            lock.lock()
            cachedDDCBrightness[ctx.primaryKey] = brightness
            lock.unlock()
        }
        if caps.isReachable && caps.supportsVolume,
           let vol = ddcBackend.readVolume(endpointIndex: ctx.resolvedIndex) {
            lock.lock()
            cachedDDCVolumes[ctx.primaryKey] = vol
            lock.unlock()
        }

        return caps
    }

    public func cachedCapabilities(for endpoint: DDCDisplayEndpoint) -> DDCCapabilities? {
        let ctx = resolveDisplayContext(endpointIndex: endpoint.index)
        lock.lock()
        defer { lock.unlock() }
        for key in ctx.lookupKeys {
            if let caps = cachedCapabilities[key] {
                return caps
            }
        }
        return cachedCapabilities[endpoint.storageKey]
    }

    public func readDDCBrightness(endpointIndex: Int, displayUUID: String? = nil) -> Int? {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        if let val = ddcBackend.readBrightness(endpointIndex: ctx.resolvedIndex) {
            lock.lock()
            cachedDDCBrightness[ctx.primaryKey] = val
            lock.unlock()
            return val
        }
        return nil
    }

    @discardableResult
    public func setDDCBrightness(_ percent: Int, endpointIndex: Int, displayUUID: String? = nil) -> Bool {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        let clamped = min(max(percent, 0), 100)
        lock.lock()
        cachedDDCBrightness[ctx.primaryKey] = clamped
        lock.unlock()
        return ddcBackend.setBrightness(clamped, endpointIndex: ctx.resolvedIndex)
    }

    @discardableResult
    public func selectOutputDevice(id: UInt32) -> Bool {
        let ok = audioBackend.setDefaultOutputDevice(id: id)
        if ok {
            // 切换输出设备后先停止旧设备的软件音量代理，等待新设备判定是否需要
            softwareVolume.deactivate()
        }
        return ok
    }

    /// 读取当前默认输出设备的音量快照：CoreAudio -> DDC 硬件音量 -> 软件音量（按需启用）
    public func currentVolumeSnapshot(
        readHardwareDDC: Bool = false,
        activateSoftwareVolumeIfNeeded: Bool = false
    ) -> AudioVolumeSnapshot {
        let devices = audioBackend.listOutputDevices()
        guard let active = devices.first(where: \.isDefault) ?? devices.first else {
            softwareVolume.deactivate()
            return AudioVolumeSnapshot(deviceID: nil, deviceName: nil, volume: 0, isMuted: false, mode: .unsupported)
        }

        // 1. 支持原生 CoreAudio 音量 -> 直接走系统硬件音量，释放软件音量代理
        if active.supportsCoreAudioVolume {
            softwareVolume.deactivate()
            let vol = audioBackend.readCoreAudioVolume(deviceID: active.id) ?? 0.5
            let muted = audioBackend.readCoreAudioMuted(deviceID: active.id) ?? false
            return AudioVolumeSnapshot(
                deviceID: active.id,
                deviceName: active.name,
                volume: vol,
                isMuted: muted,
                mode: .coreAudio
            )
        }

        // 2. 尝试匹配 DDC/CI 硬件音量（仅当端点可达且支持 VCP 0x62 时使用）
        if let endpoint = matchDDCEndpoint(for: active, allDevices: devices) {
            let ctx = resolveDisplayContext(endpointIndex: endpoint.index)
            lock.lock()
            let caps = ctx.lookupKeys.compactMap { cachedCapabilities[$0] }.first
            let cachedVol = ctx.lookupKeys.compactMap { cachedDDCVolumes[$0] }.first
            let muted = ctx.lookupKeys.compactMap { cachedDDCMuted[$0] }.first ?? false
            lock.unlock()

            let ddcVolumeAllowed: Bool
            if let caps {
                ddcVolumeAllowed = caps.isReachable && caps.supportsVolume
            } else {
                // 尚未完成异步能力探测时，暂不盲目判定不可用
                ddcVolumeAllowed = true
            }

            if ddcVolumeAllowed {
                softwareVolume.deactivate()
                let level: Int
                if let cachedVol {
                    level = cachedVol
                } else if readHardwareDDC, let hw = ddcBackend.readVolume(endpointIndex: endpoint.index) {
                    lock.lock()
                    cachedDDCVolumes[ctx.primaryKey] = hw
                    lock.unlock()
                    level = hw
                } else {
                    level = 50
                }
                return AudioVolumeSnapshot(
                    deviceID: active.id,
                    deviceName: endpoint.name,
                    volume: Double(level) / 100.0,
                    isMuted: muted,
                    mode: .ddc(ddcIndex: endpoint.index, displayName: endpoint.name)
                )
            }
        }

        // 3. 硬件既不支持 CoreAudio 也不支持 DDC 音量（如 Dell U2718Q / EIZO EV3895）-> 自动回退免驱动软件音量引擎
        if isSoftwareVolumeEnabled && softwareVolume.isSupported {
            if softwareVolume.isActive && softwareVolume.activeTargetUID != active.uid {
                softwareVolume.deactivate()
            }
            lock.lock()
            let savedVol = savedSoftwareVolumes[active.uid] ?? 1.0
            let savedMute = savedSoftwareMuted[active.uid] ?? false
            lock.unlock()

            if activateSoftwareVolumeIfNeeded || (softwareVolume.isActive && softwareVolume.activeTargetUID == active.uid) {
                do {
                    try softwareVolume.activate(targetDeviceUID: active.uid, volume: savedVol, muted: savedMute)
                } catch {
                    return AudioVolumeSnapshot(
                        deviceID: active.id,
                        deviceName: active.name,
                        volume: savedVol,
                        isMuted: savedMute,
                        mode: .unsupported
                    )
                }
            }

            let vol = (softwareVolume.isActive && softwareVolume.activeTargetUID == active.uid)
                ? softwareVolume.currentVolume
                : savedVol
            let muted = (softwareVolume.isActive && softwareVolume.activeTargetUID == active.uid)
                ? softwareVolume.isMuted
                : savedMute

            return AudioVolumeSnapshot(
                deviceID: active.id,
                deviceName: active.name,
                volume: vol,
                isMuted: muted,
                mode: .software(deviceName: active.name)
            )
        }

        softwareVolume.deactivate()
        return AudioVolumeSnapshot(
            deviceID: active.id,
            deviceName: active.name,
            volume: 0,
            isMuted: false,
            mode: .unsupported
        )
    }

    @discardableResult
    public func setCurrentVolume(_ volume: Double) -> Bool {
        let clamped = min(max(volume, 0.0), 1.0)
        let snapshot = currentVolumeSnapshot(readHardwareDDC: false, activateSoftwareVolumeIfNeeded: false)

        switch snapshot.mode {
        case .coreAudio:
            guard let deviceID = snapshot.deviceID else { return false }
            if clamped > 0.001, snapshot.isMuted {
                _ = audioBackend.setCoreAudioMuted(false, deviceID: deviceID)
            }
            return audioBackend.setCoreAudioVolume(clamped, deviceID: deviceID)

        case .ddc(let ddcIndex, _):
            let percent = Int((clamped * 100.0).rounded())
            return setDDCVolume(percent, endpointIndex: ddcIndex)

        case .software:
            guard let deviceID = snapshot.deviceID,
                  let active = audioBackend.listOutputDevices().first(where: { $0.id == deviceID }) else {
                return false
            }
            lock.lock()
            savedSoftwareVolumes[active.uid] = clamped
            if clamped > 0.001 {
                savedSoftwareMuted[active.uid] = false
            }
            let mutedNow = savedSoftwareMuted[active.uid] ?? false
            lock.unlock()

            do {
                try softwareVolume.activate(targetDeviceUID: active.uid, volume: clamped, muted: mutedNow)
                softwareVolume.setVolume(clamped)
                return true
            } catch {
                return false
            }

        case .unsupported:
            return false
        }
    }

    @discardableResult
    public func setCurrentMuted(_ muted: Bool) -> Bool {
        let snapshot = currentVolumeSnapshot(readHardwareDDC: false, activateSoftwareVolumeIfNeeded: false)

        switch snapshot.mode {
        case .coreAudio:
            guard let deviceID = snapshot.deviceID else { return false }
            return audioBackend.setCoreAudioMuted(muted, deviceID: deviceID)

        case .ddc(let ddcIndex, _):
            return setDDCMuted(muted, endpointIndex: ddcIndex)

        case .software:
            guard let deviceID = snapshot.deviceID,
                  let active = audioBackend.listOutputDevices().first(where: { $0.id == deviceID }) else {
                return false
            }
            lock.lock()
            savedSoftwareMuted[active.uid] = muted
            let volNow = savedSoftwareVolumes[active.uid] ?? 1.0
            lock.unlock()

            do {
                try softwareVolume.activate(targetDeviceUID: active.uid, volume: volNow, muted: muted)
                softwareVolume.setMuted(muted)
                return true
            } catch {
                return false
            }

        case .unsupported:
            return false
        }
    }

    @discardableResult
    public func setDDCVolume(_ percent: Int, endpointIndex: Int, displayUUID: String? = nil) -> Bool {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        let clamped = min(max(percent, 0), 100)
        lock.lock()
        let wasMuted = cachedDDCMuted[ctx.primaryKey] ?? false
        cachedDDCVolumes[ctx.primaryKey] = clamped
        if clamped > 0 {
            preMuteDDCVolumes[ctx.primaryKey] = clamped
            cachedDDCMuted[ctx.primaryKey] = false
        }
        lock.unlock()

        if clamped > 0 && wasMuted {
            // 清理可能残留的硬件静音状态（VCP 0x8D = 2）
            _ = ddcBackend.setMuted(false, endpointIndex: ctx.resolvedIndex)
        }
        return ddcBackend.setVolume(clamped, endpointIndex: ctx.resolvedIndex)
    }

    @discardableResult
    public func setDDCMuted(_ muted: Bool, endpointIndex: Int, displayUUID: String? = nil) -> Bool {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        lock.lock()
        cachedDDCMuted[ctx.primaryKey] = muted
        let currentCached = cachedDDCVolumes[ctx.primaryKey]
        let savedPreMute = preMuteDDCVolumes[ctx.primaryKey]
        lock.unlock()

        if muted {
            // 记录静音前的非零音量；通过将 VCP 0x62 设为 0 实现 100% 可逆静音，避免 LG 等显示器收到 0x8D=1 后无法软件解除静音
            let current = currentCached
                ?? ddcBackend.readVolume(endpointIndex: ctx.resolvedIndex)
                ?? 50
            lock.lock()
            if current > 0 {
                preMuteDDCVolumes[ctx.primaryKey] = current
            }
            cachedDDCVolumes[ctx.primaryKey] = 0
            lock.unlock()
            return ddcBackend.setVolume(0, endpointIndex: ctx.resolvedIndex)
        } else {
            // 先补发一次 VCP 0x8D = 2 尝试清理可能已存在的硬件静音锁，再通过 VCP 0x62 恢复静音前音量
            _ = ddcBackend.setMuted(false, endpointIndex: ctx.resolvedIndex)
            let cached = currentCached ?? 0
            let restoreVolume = savedPreMute ?? (cached > 0 ? cached : 50)
            lock.lock()
            cachedDDCVolumes[ctx.primaryKey] = restoreVolume
            lock.unlock()
            return ddcBackend.setVolume(restoreVolume, endpointIndex: ctx.resolvedIndex)
        }
    }

    @discardableResult
    public func setDisplayInputSource(
        _ source: DisplayInputSource,
        endpointIndex: Int,
        protocolMode: InputSourceProtocolMode = .auto,
        displayUUID: String? = nil
    ) -> Bool {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        if let code = calibratedCode(for: source, lookupKeys: ctx.lookupKeys) {
            return ddcBackend.writeRawInputCode(code, endpointIndex: ctx.resolvedIndex)
        }
        let effectiveProtocol = resolvedProtocolOverride(forLookupKeys: ctx.lookupKeys) ?? protocolMode
        return ddcBackend.setInputSource(
            source,
            endpointIndex: ctx.resolvedIndex,
            protocolMode: effectiveProtocol,
            hint: ctx.hint
        )
    }

    public func readDisplayInputStatus(endpointIndex: Int, displayUUID: String? = nil) -> DisplayInputStatus {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        let raw = ddcBackend.readInputSource(endpointIndex: ctx.resolvedIndex, hint: ctx.hint)
        let calibrated = calibratedCodesMap(forLookupKeys: ctx.lookupKeys)
        let active = DisplayInputSource.resolve(from: raw, calibrated: calibrated)
        let status = DisplayInputStatus(activeSource: active, rawRead: raw, calibratedCodes: calibrated)
        lock.lock()
        cachedInputStatuses[ctx.primaryKey] = status
        lock.unlock()
        return status
    }

    public func cachedDisplayInputStatus(endpointIndex: Int, displayUUID: String? = nil) -> DisplayInputStatus? {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        lock.lock()
        defer { lock.unlock() }
        for key in ctx.lookupKeys {
            if let status = cachedInputStatuses[key] {
                return status
            }
        }
        return nil
    }

    /// 读取当前亮屏端口的真实硬件 VCP 码，并永久校准绑定到指定输入源（解决不同型号 USB-C 编码差异）
    @discardableResult
    public func calibrateCurrentInputSource(
        as source: DisplayInputSource,
        endpointIndex: Int,
        displayUUID: String? = nil
    ) -> DDCInputCode? {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        guard ctx.endpoint != nil else {
            return nil
        }
        let read = ddcBackend.readInputSource(endpointIndex: ctx.resolvedIndex, hint: ctx.hint)
        guard let code = read.preferredCode else {
            return nil
        }

        saveCalibratedInputCode(code, for: source, primaryKey: ctx.primaryKey, lookupKeys: ctx.lookupKeys, rawRead: read)
        return code
    }

    /// 手动为指定输入源绑定精确硬件 DDC 编码（适用于 0xF4 只写不回读的 LG 显示器），传 nil 可单独清除该端口绑定
    public func setManualInputCode(
        _ code: DDCInputCode?,
        for source: DisplayInputSource,
        endpointIndex: Int,
        displayUUID: String? = nil
    ) {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)
        lock.lock()
        var map = calibratedInputCodes[ctx.primaryKey] ?? [:]
        if let code {
            map[source.rawValue] = code
        } else {
            map.removeValue(forKey: source.rawValue)
        }
        if map.isEmpty {
            calibratedInputCodes.removeValue(forKey: ctx.primaryKey)
        } else {
            calibratedInputCodes[ctx.primaryKey] = map
        }
        let snapshotToSave = calibratedInputCodes
        let existingStatus = cachedInputStatuses[ctx.primaryKey]
        lock.unlock()

        var state = store.loadState()
        state.calibratedInputCodes = snapshotToSave
        store.saveState(state)

        let updatedCodes = calibratedCodesMap(forLookupKeys: ctx.lookupKeys)
        let rawRead = existingStatus?.rawRead ?? DDCInputReadResult()
        let resolvedActive = DisplayInputSource.resolve(from: rawRead, calibrated: updatedCodes) ?? existingStatus?.activeSource
        let updated = DisplayInputStatus(activeSource: resolvedActive, rawRead: rawRead, calibratedCodes: updatedCodes)
        lock.lock()
        cachedInputStatuses[ctx.primaryKey] = updated
        lock.unlock()
    }

    public func resetInputCalibration(endpointIndex: Int, displayUUID: String? = nil) {
        let ctx = resolveDisplayContext(endpointIndex: endpointIndex, displayUUID: displayUUID)

        lock.lock()
        for key in ctx.lookupKeys {
            calibratedInputCodes.removeValue(forKey: key)
            cachedInputStatuses.removeValue(forKey: key)
        }
        let snapshotToSave = calibratedInputCodes
        lock.unlock()

        var state = store.loadState()
        state.calibratedInputCodes = snapshotToSave
        store.saveState(state)
    }

    /// 读取单台显示器的输入源协议覆盖设置（nil 表示跟随全局默认协议）
    public func displayInputProtocol(forDisplayUUID uuid: String) -> InputSourceProtocolMode? {
        lock.lock()
        defer { lock.unlock() }
        return displayInputProtocols["uuid:\(uuid)"] ?? displayInputProtocols[uuid]
    }

    /// 设置或清除（传 nil）单台显示器的专属输入源协议模式（例如：左屏标准 0x60、右屏强制 LG 0xF4）
    public func setDisplayInputProtocol(_ mode: InputSourceProtocolMode?, forDisplayUUID uuid: String) {
        let key = "uuid:\(uuid)"
        lock.lock()
        displayInputProtocols.removeValue(forKey: uuid)
        if let mode {
            displayInputProtocols[key] = mode
        } else {
            displayInputProtocols.removeValue(forKey: key)
        }
        let snapshotToSave = displayInputProtocols
        lock.unlock()

        var state = store.loadState()
        state.displayInputProtocols = snapshotToSave
        store.saveState(state)
    }

    /// 手动纠偏并持久化某台显示器对应的 DDC 硬件通道（若另一台屏占用了该通道会自动互换）
    public func bindDisplay(
        _ displayUUID: String,
        toEndpoint endpoint: DDCDisplayEndpoint
    ) {
        lock.lock()
        let oldKeyForDisplay = preferredDDCKeyByDisplayUUID[displayUUID]
        // 如果其他显示器曾绑定到此通道，顺手互换，避免冲突
        if let conflictUUID = preferredDDCKeyByDisplayUUID.first(where: { $0.key != displayUUID && $0.value == endpoint.storageKey })?.key {
            if let oldKeyForDisplay {
                preferredDDCKeyByDisplayUUID[conflictUUID] = oldKeyForDisplay
            } else {
                preferredDDCKeyByDisplayUUID.removeValue(forKey: conflictUUID)
            }
        }
        preferredDDCKeyByDisplayUUID[displayUUID] = endpoint.storageKey
        let snapshotToSave = preferredDDCKeyByDisplayUUID
        lock.unlock()

        var state = store.loadState()
        state.displayToDDCBindings = snapshotToSave
        store.saveState(state)
    }

    public func bindDDCEndpoint(_ endpointIndex: Int, forAudioDeviceUID uid: String) {
        lock.lock()
        let oldIdx = preferredDDCEndpointByAudioUID[uid]
        // 若另一台音频设备曾绑定到此端点，自动互换防止出现两台音频输出都指向同一屏幕
        if let conflictUID = preferredDDCEndpointByAudioUID.first(where: { $0.key != uid && $0.value == endpointIndex })?.key {
            if let oldIdx {
                preferredDDCEndpointByAudioUID[conflictUID] = oldIdx
            } else {
                preferredDDCEndpointByAudioUID.removeValue(forKey: conflictUID)
            }
        }
        preferredDDCEndpointByAudioUID[uid] = endpointIndex
        let snapshotToSave = preferredDDCEndpointByAudioUID
        lock.unlock()

        var state = store.loadState()
        state.audioToDDCBindings = snapshotToSave
        store.saveState(state)
    }

    /// 全局一对一独占匹配：将所有已启用的外接显示器精准映射到各自的 DDC 端点，绝不受自定义改名排序影响
    public func matchAllDDCEndpoints(
        for displays: [DisplayInfo],
        endpoints: [DDCDisplayEndpoint]? = nil
    ) -> [String: Int] {
        guard ddcBackend.isAvailable else { return [:] }
        let eps = endpoints ?? ddcBackend.listEndpoints()
        guard !eps.isEmpty else { return [:] }

        let enabledExternals = displays
            .filter { !$0.isBuiltin && $0.isEnabledForDisplay }
            .sorted { $0.id < $1.id }

        var result: [String: Int] = [:]
        var usedEndpoints = Set<Int>()

        lock.lock()
        let savedBindings = preferredDDCKeyByDisplayUUID
        lock.unlock()

        // 第 1 轮：跨插拔稳定的持久化手动绑定（如基于唯一序列号 serial:... 的纠偏；易随插线顺序改变的 port:dispextN 不抢占物理管线）
        for display in enabledExternals {
            if let targetKey = savedBindings[display.uuid],
               !targetKey.hasPrefix("port:"),
               let ep = eps.first(where: { !usedEndpoints.contains($0.index) && $0.storageKey == targetKey }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 2 轮：Apple Silicon 物理硬件管线精准对齐（dispext0 == dispext0, dispext1 == dispext1）
        for display in enabledExternals where result[display.uuid] == nil {
            if let token = display.displayPortToken,
               let ep = eps.first(where: { !usedEndpoints.contains($0.index) && $0.displayPortToken == token }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 3 轮：32-bit 数字 EDID 序列号精确匹配
        for display in enabledExternals where result[display.uuid] == nil {
            if let num = display.numericSerial, num != 0,
               let ep = eps.first(where: { !usedEndpoints.contains($0.index) && $0.numericSerial == num }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 4 轮：字母数字序列号精确匹配
        for display in enabledExternals where result[display.uuid] == nil {
            if let serial = display.serialNumber?.lowercased(), serial.count >= 4,
               let ep = eps.first(where: {
                   guard !usedEndpoints.contains($0.index),
                         let epSerial = $0.serialNumber?.lowercased(), !epSerial.isEmpty else {
                       return false
                   }
                   return epSerial == serial || epSerial.contains(serial) || serial.contains(epSerial)
               }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 4.5 轮：无物理管线与序列号时的端口手动绑定兜底
        for display in enabledExternals where result[display.uuid] == nil {
            if let targetKey = savedBindings[display.uuid],
               let ep = eps.first(where: { !usedEndpoints.contains($0.index) && $0.storageKey == targetKey }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 5 轮：系统型号名模糊匹配（按稳定 displayID 顺序一对一独占分配）
        func normalize(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        for display in enabledExternals where result[display.uuid] == nil {
            let normSys = normalize(display.systemName)
            guard !normSys.isEmpty else { continue }
            if let ep = eps.first(where: {
                guard !usedEndpoints.contains($0.index) else { return false }
                let normEP = normalize($0.name)
                return !normEP.isEmpty && (normSys.contains(normEP) || normEP.contains(normSys))
            }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 6 轮：按稳定 displayID 顺序兜底独占分配剩余端点
        for display in enabledExternals where result[display.uuid] == nil {
            if let ep = eps.first(where: { !usedEndpoints.contains($0.index) }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        return result
    }

    /// 全局一对一独占匹配：将所有不支持系统音量的外接音频输出设备精准映射到各自的 DDC 端点（杜绝重复撞车）
    public func matchAllAudioToDDCEndpoints(
        audioDevices: [AudioOutputDevice]? = nil,
        displays: [DisplayInfo]? = nil,
        endpoints: [DDCDisplayEndpoint]? = nil
    ) -> [UInt32: Int] {
        guard ddcBackend.isAvailable else { return [:] }
        let eps = endpoints ?? ddcBackend.listEndpoints()
        guard !eps.isEmpty else { return [:] }

        let allDevices = audioDevices ?? audioBackend.listOutputDevices()
        let excludedTransports: Set<AudioTransportType> = [.builtIn, .bluetooth, .airPlay, .virtual]
        let externalAudios = allDevices.filter {
            !$0.supportsCoreAudioVolume && !excludedTransports.contains($0.transport)
        }
        guard !externalAudios.isEmpty else { return [:] }

        lock.lock()
        let resolvedDisplays = displays ?? knownDisplays
        let savedAudioBindings = preferredDDCEndpointByAudioUID
        lock.unlock()

        let displayToDDC = matchAllDDCEndpoints(for: resolvedDisplays, endpoints: eps)

        var result: [UInt32: Int] = [:]
        var usedEndpoints = Set<Int>()

        // 第 1 轮：CoreAudio EDID UID 硬件指纹精准解码（VVVVMMMM-...，其中 VVVV=VendorID，MMMM=小端序 ModelID）
        // 当硬件指纹唯一锁定某台显示器时直接信任物理事实，不受旧版本历史脏绑定干扰
        for device in externalAudios {
            if let parsed = parseEDIDAudioUID(device.uid) {
                let matchingDisplays = resolvedDisplays.filter { d in
                    guard !d.isBuiltin, let dVendor = d.vendorID, let dModel = d.modelID else { return false }
                    return dVendor == parsed.vendorID && (dModel == parsed.modelSwapped || dModel == parsed.modelRaw)
                }
                if matchingDisplays.count == 1,
                   let d = matchingDisplays.first,
                   let epIdx = displayToDDC[d.uuid],
                   !usedEndpoints.contains(epIdx) {
                    result[device.id] = epIdx
                    usedEndpoints.insert(epIdx)
                }
            }
        }

        // 第 2 轮：持久化手动绑定（保证独占，避免旧数据导致两台设备指向同一端点）
        for device in externalAudios where result[device.id] == nil {
            if let preferred = savedAudioBindings[device.uid],
               eps.contains(where: { $0.index == preferred }),
               !usedEndpoints.contains(preferred) {
                result[device.id] = preferred
                usedEndpoints.insert(preferred)
            }
        }

        // 第 3 轮：UID 中的 dispextN 端口路径或序列号精准匹配
        for device in externalAudios where result[device.id] == nil {
            let loweredUID = device.uid.lowercased()
            if let token = extractDispExtToken(from: loweredUID),
               let ep = eps.first(where: { !usedEndpoints.contains($0.index) && $0.displayPortToken == token }) {
                result[device.id] = ep.index
                usedEndpoints.insert(ep.index)
                continue
            }
            if let ep = eps.first(where: {
                guard !usedEndpoints.contains($0.index),
                      let serial = $0.serialNumber?.lowercased(), serial.count >= 4 else { return false }
                return loweredUID.contains(serial)
            }) {
                result[device.id] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 4 轮：名称模糊一对一独占匹配
        func normalize(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        for device in externalAudios where result[device.id] == nil {
            let normDev = normalize(device.name)
            guard !normDev.isEmpty else { continue }
            if let ep = eps.first(where: {
                guard !usedEndpoints.contains($0.index) else { return false }
                let normEP = normalize($0.name)
                return !normEP.isEmpty && (normDev.contains(normEP) || normEP.contains(normDev))
            }) {
                result[device.id] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 5 轮：按剩余空闲端点一对一兜底分配
        for device in externalAudios where result[device.id] == nil {
            if let ep = eps.first(where: { !usedEndpoints.contains($0.index) }) {
                result[device.id] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        return result
    }

    /// 便捷方法：返回单台显示器对应的 DDC 端点（复用全局一对一算法）
    public func matchDDCEndpoint(
        for display: DisplayInfo,
        allDisplays: [DisplayInfo],
        endpoints: [DDCDisplayEndpoint]? = nil
    ) -> DDCDisplayEndpoint? {
        let eps = endpoints ?? ddcBackend.listEndpoints()
        let mapping = matchAllDDCEndpoints(for: allDisplays, endpoints: eps)
        guard let idx = mapping[display.uuid] else { return nil }
        return eps.first(where: { $0.index == idx })
    }

    /// 便捷方法：返回某音频输出设备对应的 DDC 端点索引（复用全局一对一独占映射）
    public func matchedDDCEndpointIndex(
        for device: AudioOutputDevice,
        allDevices: [AudioOutputDevice]? = nil,
        displays: [DisplayInfo]? = nil
    ) -> Int? {
        guard !device.supportsCoreAudioVolume else { return nil }
        let mapping = matchAllAudioToDDCEndpoints(audioDevices: allDevices, displays: displays)
        return mapping[device.id]
    }

    private func matchDDCEndpoint(
        for device: AudioOutputDevice,
        allDevices: [AudioOutputDevice]
    ) -> DDCDisplayEndpoint? {
        let eps = ddcBackend.listEndpoints()
        let mapping = matchAllAudioToDDCEndpoints(audioDevices: allDevices, endpoints: eps)
        guard let idx = mapping[device.id] else { return nil }
        return eps.first(where: { $0.index == idx })
    }

    /// 解码 macOS CoreAudio HDMI/DP 设备的 EDID UID 前 8 位（例：1E6D9D5C-... -> vendor=0x1E6D, modelSwapped=0x5C9D）
    private func parseEDIDAudioUID(_ uid: String) -> (vendorID: UInt32, modelRaw: UInt32, modelSwapped: UInt32)? {
        let prefix = String(uid.prefix(8))
        guard prefix.count == 8,
              prefix.allSatisfy(\.isHexDigit),
              let vendor = UInt32(prefix.prefix(4), radix: 16),
              let modelRaw = UInt32(prefix.suffix(4), radix: 16),
              vendor != 0 else {
            return nil
        }
        let modelSwapped = ((modelRaw & 0xFF) << 8) | ((modelRaw >> 8) & 0xFF)
        return (vendor, modelRaw, modelSwapped)
    }

    private func extractDispExtToken(from text: String) -> String? {
        guard let range = text.range(of: #"dispext\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    private struct ResolvedDisplayDDCContext {
        let endpoint: DDCDisplayEndpoint?
        let resolvedIndex: Int
        let display: DisplayInfo?
        let primaryKey: String
        let lookupKeys: [String]
        let hint: DDCDisplayHint
    }

    private func resolveDisplayContext(
        endpointIndex: Int,
        displayUUID: String? = nil,
        endpoints: [DDCDisplayEndpoint]? = nil
    ) -> ResolvedDisplayDDCContext {
        let eps = endpoints ?? ddcBackend.listEndpoints()
        lock.lock()
        let displaysSnapshot = knownDisplays
        lock.unlock()

        let displayMapping: [String: Int] = displaysSnapshot.isEmpty
            ? [:]
            : matchAllDDCEndpoints(for: displaysSnapshot, endpoints: eps)

        let matchedDisplay: DisplayInfo?
        let resolvedIndex: Int
        if let uuid = displayUUID, !uuid.isEmpty {
            matchedDisplay = displaysSnapshot.first(where: { $0.uuid == uuid })
            resolvedIndex = displayMapping[uuid] ?? endpointIndex
        } else {
            resolvedIndex = endpointIndex
            if let matchedUUID = displayMapping.first(where: { $0.value == endpointIndex })?.key {
                matchedDisplay = displaysSnapshot.first(where: { $0.uuid == matchedUUID })
            } else {
                matchedDisplay = nil
            }
        }

        let endpoint = eps.first(where: { $0.index == resolvedIndex })
        let primaryKey: String
        if let d = matchedDisplay {
            primaryKey = "uuid:\(d.uuid)"
        } else if let uuid = displayUUID, !uuid.isEmpty {
            primaryKey = "uuid:\(uuid)"
        } else if let ep = endpoint {
            primaryKey = ep.storageKey
        } else {
            primaryKey = "endpoint:\(resolvedIndex)"
        }

        var lookupKeys = [primaryKey]
        if let ep = endpoint, ep.storageKey != primaryKey, !ep.storageKey.hasPrefix("port:") {
            lookupKeys.append(ep.storageKey)
        }

        lock.lock()
        let knownCaps = lookupKeys.compactMap { cachedCapabilities[$0] }.first
        lock.unlock()

        let hint = matchedDisplay.map { DDCDisplayHint(display: $0, capabilities: knownCaps) }
            ?? DDCDisplayHint(capabilities: knownCaps)
        return ResolvedDisplayDDCContext(
            endpoint: endpoint,
            resolvedIndex: resolvedIndex,
            display: matchedDisplay,
            primaryKey: primaryKey,
            lookupKeys: lookupKeys,
            hint: hint
        )
    }

    /// 一键清空所有历史手动 DDC 通道绑定、端口校准与单屏协议覆盖，恢复纯粹硬件自动匹配
    public func resetAllDDCCustomizations() {
        lock.lock()
        preferredDDCEndpointByAudioUID.removeAll()
        preferredDDCKeyByDisplayUUID.removeAll()
        calibratedInputCodes.removeAll()
        displayInputProtocols.removeAll()
        cachedInputStatuses.removeAll()
        lock.unlock()

        var state = store.loadState()
        state.audioToDDCBindings = [:]
        state.displayToDDCBindings = [:]
        state.calibratedInputCodes = [:]
        state.displayInputProtocols = [:]
        store.saveState(state)
    }

    private func saveCalibratedInputCode(
        _ code: DDCInputCode,
        for source: DisplayInputSource,
        primaryKey: String,
        lookupKeys: [String],
        rawRead: DDCInputReadResult
    ) {
        lock.lock()
        var map = calibratedInputCodes[primaryKey] ?? [:]
        map[source.rawValue] = code
        calibratedInputCodes[primaryKey] = map
        let snapshotToSave = calibratedInputCodes
        lock.unlock()

        var state = store.loadState()
        state.calibratedInputCodes = snapshotToSave
        store.saveState(state)

        let updated = DisplayInputStatus(
            activeSource: source,
            rawRead: rawRead,
            calibratedCodes: calibratedCodesMap(forLookupKeys: lookupKeys)
        )
        lock.lock()
        cachedInputStatuses[primaryKey] = updated
        lock.unlock()
    }

    private func resolvedProtocolOverride(forLookupKeys keys: [String]) -> InputSourceProtocolMode? {
        lock.lock()
        defer { lock.unlock() }
        for key in keys {
            if let mode = displayInputProtocols[key] {
                return mode
            }
        }
        return nil
    }

    private func calibratedCode(for source: DisplayInputSource, lookupKeys: [String]) -> DDCInputCode? {
        lock.lock()
        defer { lock.unlock() }
        for key in lookupKeys {
            if let code = calibratedInputCodes[key]?[source.rawValue] {
                return code
            }
        }
        return nil
    }

    private func calibratedCodesMap(forLookupKeys keys: [String]) -> [DisplayInputSource: DDCInputCode] {
        lock.lock()
        var merged: [String: DDCInputCode] = [:]
        // 低优先级 key 先写入，primaryKey 最后覆盖
        for key in keys.reversed() {
            if let rawMap = calibratedInputCodes[key] {
                for (k, v) in rawMap {
                    merged[k] = v
                }
            }
        }
        lock.unlock()

        var result: [DisplayInputSource: DDCInputCode] = [:]
        for (rawKey, code) in merged {
            if let source = DisplayInputSource(rawValue: rawKey) {
                result[source] = code
            }
        }
        return result
    }

    public func startObservingChanges(_ handler: @escaping @Sendable () -> Void) {
        audioBackend.startObservingChanges(handler)
    }

    public func stopObservingChanges() {
        audioBackend.stopObservingChanges()
    }
}
