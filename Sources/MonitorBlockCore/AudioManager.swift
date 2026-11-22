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

/// 统一管理音频输出切换、CoreAudio 音量与外接显示器 DDC/CI 硬件音量
public final class AudioManager {
    private let audioBackend: AudioBackend
    private let ddcBackend: DDCBackend
    private let store: StateStoreProtocol
    private var cachedDDCVolumes: [Int: Int] = [:]
    private var preMuteDDCVolumes: [Int: Int] = [:]
    private var cachedDDCMuted: [Int: Bool] = [:]
    private var preferredDDCEndpointByAudioUID: [String: Int]

    public init(
        audioBackend: AudioBackend = CoreAudioBackend(),
        ddcBackend: DDCBackend = AppleSiliconDDCBackend(),
        store: StateStoreProtocol = FileStateStore()
    ) {
        self.audioBackend = audioBackend
        self.ddcBackend = ddcBackend
        self.store = store
        self.preferredDDCEndpointByAudioUID = store.loadState().audioToDDCBindings
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
    public func setDisplayInputSource(_ source: DisplayInputSource, endpointIndex: Int) -> Bool {
        ddcBackend.setInputSource(source, endpointIndex: endpointIndex)
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
