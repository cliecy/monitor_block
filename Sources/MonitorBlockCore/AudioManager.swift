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
            let name = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
                ?? "音频设备 #\(deviceID)"
            let uid = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
                ?? "audio-\(deviceID)"
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

/// 统一管理音频输出切换、CoreAudio 音量与外接显示器 DDC/CI 硬件音量及输入源
public final class AudioManager: @unchecked Sendable {
    private let audioBackend: AudioBackend
    private let ddcBackend: DDCBackend
    private let store: StateStoreProtocol
    private let lock = NSLock()
    private var cachedDDCVolumes: [Int: Int] = [:]
    private var preMuteDDCVolumes: [Int: Int] = [:]
    private var cachedDDCMuted: [Int: Bool] = [:]
    private var preferredDDCEndpointByAudioUID: [String: Int]
    private var preferredDDCKeyByDisplayUUID: [String: String]
    private var calibratedInputCodes: [String: [String: DDCInputCode]]
    private var cachedInputStatuses: [Int: DisplayInputStatus] = [:]

    public init(
        audioBackend: AudioBackend = CoreAudioBackend(),
        ddcBackend: DDCBackend = AppleSiliconDDCBackend(),
        store: StateStoreProtocol = FileStateStore()
    ) {
        self.audioBackend = audioBackend
        self.ddcBackend = ddcBackend
        self.store = store
        let loaded = store.loadState()
        self.preferredDDCEndpointByAudioUID = loaded.audioToDDCBindings
        self.preferredDDCKeyByDisplayUUID = loaded.displayToDDCBindings
        self.calibratedInputCodes = loaded.calibratedInputCodes
    }

    public func listOutputDevices() -> [AudioOutputDevice] {
        audioBackend.listOutputDevices()
    }

    public func listDDCEndpoints() -> [DDCDisplayEndpoint] {
        ddcBackend.listEndpoints().map { endpoint in
            let cachedVol = cachedDDCVolumes[endpoint.index]
            let cachedMute = cachedDDCMuted[endpoint.index] ?? false
            return DDCDisplayEndpoint(
                index: endpoint.index,
                name: endpoint.name,
                serialNumber: endpoint.serialNumber,
                numericSerial: endpoint.numericSerial,
                registryPath: endpoint.registryPath,
                currentVolume: cachedVol,
                isMuted: cachedMute
            )
        }
    }

    @discardableResult
    public func selectOutputDevice(id: UInt32) -> Bool {
        audioBackend.setDefaultOutputDevice(id: id)
    }

    /// 读取当前默认输出设备的音量快照（若为不支持系统音量的外接屏，自动桥接 DDC/CI）
    public func currentVolumeSnapshot(readHardwareDDC: Bool = false) -> AudioVolumeSnapshot {
        let devices = audioBackend.listOutputDevices()
        guard let active = devices.first(where: \.isDefault) ?? devices.first else {
            return AudioVolumeSnapshot(deviceID: nil, deviceName: nil, volume: 0, isMuted: false, mode: .unsupported)
        }

        if active.supportsCoreAudioVolume {
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

        if let endpoint = matchDDCEndpoint(for: active, allDevices: devices) {
            let level: Int
            if let cached = cachedDDCVolumes[endpoint.index] {
                level = cached
            } else if readHardwareDDC, let hw = ddcBackend.readVolume(endpointIndex: endpoint.index) {
                cachedDDCVolumes[endpoint.index] = hw
                level = hw
            } else {
                level = 50
            }
            let muted = cachedDDCMuted[endpoint.index] ?? false
            return AudioVolumeSnapshot(
                deviceID: active.id,
                deviceName: endpoint.name,
                volume: Double(level) / 100.0,
                isMuted: muted,
                mode: .ddc(ddcIndex: endpoint.index, displayName: endpoint.name)
            )
        }

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
        let snapshot = currentVolumeSnapshot(readHardwareDDC: false)

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

        case .unsupported:
            return false
        }
    }

    @discardableResult
    public func setCurrentMuted(_ muted: Bool) -> Bool {
        let snapshot = currentVolumeSnapshot(readHardwareDDC: false)

        switch snapshot.mode {
        case .coreAudio:
            guard let deviceID = snapshot.deviceID else { return false }
            return audioBackend.setCoreAudioMuted(muted, deviceID: deviceID)

        case .ddc(let ddcIndex, _):
            return setDDCMuted(muted, endpointIndex: ddcIndex)

        case .unsupported:
            return false
        }
    }

    @discardableResult
    public func setDDCVolume(_ percent: Int, endpointIndex: Int) -> Bool {
        let clamped = min(max(percent, 0), 100)
        let wasMuted = cachedDDCMuted[endpointIndex] ?? false
        cachedDDCVolumes[endpointIndex] = clamped

        if clamped > 0 {
            preMuteDDCVolumes[endpointIndex] = clamped
            cachedDDCMuted[endpointIndex] = false
            if wasMuted {
                // 清理可能残留的硬件静音状态（VCP 0x8D = 2）
                _ = ddcBackend.setMuted(false, endpointIndex: endpointIndex)
            }
        }
        return ddcBackend.setVolume(clamped, endpointIndex: endpointIndex)
    }

    @discardableResult
    public func setDDCMuted(_ muted: Bool, endpointIndex: Int) -> Bool {
        cachedDDCMuted[endpointIndex] = muted
        if muted {
            // 记录静音前的非零音量；通过将 VCP 0x62 设为 0 实现 100% 可逆静音，避免 LG 等显示器收到 0x8D=1 后无法软件解除静音
            let current = cachedDDCVolumes[endpointIndex]
                ?? ddcBackend.readVolume(endpointIndex: endpointIndex)
                ?? 50
            if current > 0 {
                preMuteDDCVolumes[endpointIndex] = current
            }
            cachedDDCVolumes[endpointIndex] = 0
            return ddcBackend.setVolume(0, endpointIndex: endpointIndex)
        } else {
            // 先补发一次 VCP 0x8D = 2 尝试清理可能已存在的硬件静音锁，再通过 VCP 0x62 恢复静音前音量
            _ = ddcBackend.setMuted(false, endpointIndex: endpointIndex)
            let cached = cachedDDCVolumes[endpointIndex] ?? 0
            let restoreVolume = preMuteDDCVolumes[endpointIndex] ?? (cached > 0 ? cached : 50)
            cachedDDCVolumes[endpointIndex] = restoreVolume
            return ddcBackend.setVolume(restoreVolume, endpointIndex: endpointIndex)
        }
    }

    @discardableResult
    public func setDisplayInputSource(
        _ source: DisplayInputSource,
        endpointIndex: Int,
        protocolMode: InputSourceProtocolMode = .auto
    ) -> Bool {
        if let code = calibratedCode(for: source, endpointIndex: endpointIndex) {
            return ddcBackend.writeRawInputCode(code, endpointIndex: endpointIndex)
        }
        return ddcBackend.setInputSource(source, endpointIndex: endpointIndex, protocolMode: protocolMode)
    }

    public func readDisplayInputStatus(endpointIndex: Int) -> DisplayInputStatus {
        let raw = ddcBackend.readInputSource(endpointIndex: endpointIndex)
        let calibrated = calibratedCodesMap(forEndpointIndex: endpointIndex)
        let active = DisplayInputSource.resolve(from: raw, calibrated: calibrated)
        let status = DisplayInputStatus(activeSource: active, rawRead: raw, calibratedCodes: calibrated)
        lock.lock()
        cachedInputStatuses[endpointIndex] = status
        lock.unlock()
        return status
    }

    public func cachedDisplayInputStatus(endpointIndex: Int) -> DisplayInputStatus? {
        lock.lock()
        defer { lock.unlock() }
        return cachedInputStatuses[endpointIndex]
    }

    /// 读取当前亮屏端口的真实硬件 VCP 码，并永久校准绑定到指定输入源（解决不同型号 USB-C 编码差异）
    @discardableResult
    public func calibrateCurrentInputSource(
        as source: DisplayInputSource,
        endpointIndex: Int
    ) -> DDCInputCode? {
        let endpoints = ddcBackend.listEndpoints()
        guard let endpoint = endpoints.first(where: { $0.index == endpointIndex }) else {
            return nil
        }
        let read = ddcBackend.readInputSource(endpointIndex: endpointIndex)
        guard let code = read.preferredCode else {
            return nil
        }

        lock.lock()
        var map = calibratedInputCodes[endpoint.storageKey] ?? [:]
        map[source.rawValue] = code
        calibratedInputCodes[endpoint.storageKey] = map
        let snapshotToSave = calibratedInputCodes
        lock.unlock()

        var state = store.loadState()
        state.calibratedInputCodes = snapshotToSave
        store.saveState(state)

        // 更新缓存状态使高亮立刻生效
        let updated = DisplayInputStatus(
            activeSource: source,
            rawRead: read,
            calibratedCodes: calibratedCodesMap(forStorageKey: endpoint.storageKey)
        )
        lock.lock()
        cachedInputStatuses[endpointIndex] = updated
        lock.unlock()
        return code
    }

    public func resetInputCalibration(endpointIndex: Int) {
        let endpoints = ddcBackend.listEndpoints()
        guard let endpoint = endpoints.first(where: { $0.index == endpointIndex }) else { return }

        lock.lock()
        calibratedInputCodes.removeValue(forKey: endpoint.storageKey)
        let snapshotToSave = calibratedInputCodes
        cachedInputStatuses.removeValue(forKey: endpointIndex)
        lock.unlock()

        var state = store.loadState()
        state.calibratedInputCodes = snapshotToSave
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

    /// 全局一对一独占匹配：将所有已启用的外接显示器精准映射到各自的 DDC 端点，绝不受自定义改名排序影响
    public func matchAllDDCEndpoints(
        for displays: [DisplayInfo],
        endpoints: [DDCDisplayEndpoint]? = nil
    ) -> [String: Int] {
        guard ddcBackend.isAvailable else { return [:] }
        let eps = endpoints ?? ddcBackend.listEndpoints()
        guard !eps.isEmpty else { return [:] }

        // 严格按 CGDirectDisplayID 稳定升序处理，绝不受用户自定义名称排序影响！
        let enabledExternals = displays
            .filter { !$0.isBuiltin && $0.isEnabledForDisplay }
            .sorted { $0.id < $1.id }

        var result: [String: Int] = [:]
        var usedEndpoints = Set<Int>()

        lock.lock()
        let savedBindings = preferredDDCKeyByDisplayUUID
        lock.unlock()

        // 第 1 轮：持久化手动绑定
        for display in enabledExternals {
            if let targetKey = savedBindings[display.uuid],
               let ep = eps.first(where: { !usedEndpoints.contains($0.index) && $0.storageKey == targetKey }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 2 轮：32-bit 数字 EDID 序列号精确匹配（Apple Silicon CoreGraphics 与 IOKit 两端通用！）
        for display in enabledExternals where result[display.uuid] == nil {
            if let num = display.numericSerial, num != 0,
               let ep = eps.first(where: { !usedEndpoints.contains($0.index) && $0.numericSerial == num }) {
                result[display.uuid] = ep.index
                usedEndpoints.insert(ep.index)
            }
        }

        // 第 3 轮：字母数字序列号精确匹配
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

        // 第 4 轮：系统型号名模糊匹配（按稳定 displayID 顺序一对一独占分配）
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

        // 第 5 轮：按稳定 displayID 顺序兜底独占分配剩余端点
        for display in enabledExternals where result[display.uuid] == nil {
            if let ep = eps.first(where: { !usedEndpoints.contains($0.index) }) {
                result[display.uuid] = ep.index
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

    /// 便捷方法：返回某音频输出设备对应的 DDC 端点索引（用于 UI 统一显示自定义显示器名称）
    public func matchedDDCEndpointIndex(
        for device: AudioOutputDevice,
        allDevices: [AudioOutputDevice]? = nil
    ) -> Int? {
        guard !device.supportsCoreAudioVolume else { return nil }
        let devices = allDevices ?? audioBackend.listOutputDevices()
        return matchDDCEndpoint(for: device, allDevices: devices)?.index
    }

    private func calibratedCode(for source: DisplayInputSource, endpointIndex: Int) -> DDCInputCode? {
        let endpoints = ddcBackend.listEndpoints()
        guard let endpoint = endpoints.first(where: { $0.index == endpointIndex }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return calibratedInputCodes[endpoint.storageKey]?[source.rawValue]
    }

    private func calibratedCodesMap(forEndpointIndex endpointIndex: Int) -> [DisplayInputSource: DDCInputCode] {
        let endpoints = ddcBackend.listEndpoints()
        guard let endpoint = endpoints.first(where: { $0.index == endpointIndex }) else { return [:] }
        return calibratedCodesMap(forStorageKey: endpoint.storageKey)
    }

    private func calibratedCodesMap(forStorageKey key: String) -> [DisplayInputSource: DDCInputCode] {
        lock.lock()
        let rawMap = calibratedInputCodes[key] ?? [:]
        lock.unlock()
        var result: [DisplayInputSource: DDCInputCode] = [:]
        for (rawKey, code) in rawMap {
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

    public func bindDDCEndpoint(_ endpointIndex: Int, forAudioDeviceUID uid: String) {
        preferredDDCEndpointByAudioUID[uid] = endpointIndex
        var state = store.loadState()
        state.audioToDDCBindings = preferredDDCEndpointByAudioUID
        store.saveState(state)
    }

    private func matchDDCEndpoint(
        for device: AudioOutputDevice,
        allDevices: [AudioOutputDevice]
    ) -> DDCDisplayEndpoint? {
        guard ddcBackend.isAvailable else { return nil }
        let endpoints = ddcBackend.listEndpoints()
        guard !endpoints.isEmpty else { return nil }

        // 0. 优先使用用户手动绑定并持久化的 DDC 端点
        if let preferred = preferredDDCEndpointByAudioUID[device.uid],
           let found = endpoints.first(where: { $0.index == preferred }) {
            return found
        }

        // 1. 硬件标识精准匹配：通过 CoreAudio UID 中的 dispextN 端口路径或显示器序列号对齐
        let loweredUID = device.uid.lowercased()
        if let portToken = extractDispExtToken(from: loweredUID),
           let byPort = endpoints.first(where: { ($0.registryPath?.lowercased().contains(portToken) ?? false) }) {
            return byPort
        }
        if let bySerial = endpoints.first(where: {
            guard let serial = $0.serialNumber?.lowercased(), serial.count >= 4 else { return false }
            return loweredUID.contains(serial)
        }) {
            return bySerial
        }

        // 2. 名称模糊匹配：如果命中多个同名端点（如 2 台同型号 LG），按同名音频设备中的序号一一对应，避免永远落到第 0 台
        func normalize(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let normDevice = normalize(device.name)
        if !normDevice.isEmpty {
            let matchedEndpoints = endpoints.filter {
                let normEP = normalize($0.name)
                return !normEP.isEmpty && (normDevice.contains(normEP) || normEP.contains(normDevice))
            }
            if matchedEndpoints.count == 1 {
                return matchedEndpoints[0]
            }
            if matchedEndpoints.count > 1 {
                let sameNameAudio = allDevices.filter {
                    !$0.supportsCoreAudioVolume && normalize($0.name) == normDevice
                }
                if let pos = sameNameAudio.firstIndex(where: { $0.id == device.id }),
                   matchedEndpoints.indices.contains(pos) {
                    return matchedEndpoints[pos]
                }
                return matchedEndpoints[0]
            }
        }

        // 3. 只要该设备不支持 CoreAudio 音量且属于外部直连设备（HDMI/DP/USB/Other），按非 CoreAudio 外接设备顺序兜底映射
        let excludedTransports: Set<AudioTransportType> = [.builtIn, .bluetooth, .airPlay, .virtual]
        if !excludedTransports.contains(device.transport) {
            let candidates = allDevices.filter {
                !$0.supportsCoreAudioVolume && !excludedTransports.contains($0.transport)
            }
            if let pos = candidates.firstIndex(where: { $0.id == device.id }),
               endpoints.indices.contains(pos) {
                return endpoints[pos]
            }
            return endpoints.first
        }

        return nil
    }

    private func extractDispExtToken(from text: String) -> String? {
        guard let range = text.range(of: #"dispext\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }
}
