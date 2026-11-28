import Foundation
import Testing
@testable import MonitorBlockCore

private final class MockAudioBackend: AudioBackend {
    var devices: [AudioOutputDevice] = []
    var volumes: [UInt32: Double] = [:]
    var muted: [UInt32: Bool] = [:]
    var selectedDeviceIDs: [UInt32] = []

    func listOutputDevices() -> [AudioOutputDevice] {
        devices
    }

    func defaultOutputDeviceID() -> UInt32? {
        devices.first(where: \.isDefault)?.id
    }

    func setDefaultOutputDevice(id: UInt32) -> Bool {
        guard devices.contains(where: { $0.id == id }) else { return false }
        selectedDeviceIDs.append(id)
        devices = devices.map { dev in
            AudioOutputDevice(
                id: dev.id,
                uid: dev.uid,
                name: dev.name,
                transport: dev.transport,
                isDefault: dev.id == id,
                supportsCoreAudioVolume: dev.supportsCoreAudioVolume
            )
        }
        return true
    }

    func readCoreAudioVolume(deviceID: UInt32) -> Double? {
        volumes[deviceID]
    }

    func setCoreAudioVolume(_ volume: Double, deviceID: UInt32) -> Bool {
        volumes[deviceID] = volume
        return true
    }

    func readCoreAudioMuted(deviceID: UInt32) -> Bool? {
        muted[deviceID]
    }

    func setCoreAudioMuted(_ isMuted: Bool, deviceID: UInt32) -> Bool {
        muted[deviceID] = isMuted
        return true
    }

    func startObservingChanges(_ handler: @escaping @Sendable () -> Void) {}
    func stopObservingChanges() {}
}

private final class MockSoftwareVolumeBackend: SoftwareVolumeBackend {
    var isSupported: Bool = true
    var isActive: Bool = false
    var activeTargetUID: String?
    var currentVolume: Double = 1.0
    var isMuted: Bool = false
    var lastError: String?
    var shouldFailActivate: Bool = false

    var activateCalls: [(uid: String, volume: Double, muted: Bool)] = []
    var setVolumeCalls: [Double] = []
    var setMutedCalls: [Bool] = []
    var deactivateCount: Int = 0

    func activate(targetDeviceUID: String, volume: Double, muted: Bool) throws {
        if shouldFailActivate {
            lastError = SoftwareVolumeError.tapCreationFailed(-1).localizedDescription
            throw SoftwareVolumeError.tapCreationFailed(-1)
        }
        activateCalls.append((targetDeviceUID, volume, muted))
        isActive = true
        activeTargetUID = targetDeviceUID
        currentVolume = volume
        isMuted = muted
        lastError = nil
    }

    func setVolume(_ volume: Double) {
        setVolumeCalls.append(volume)
        currentVolume = volume
        if volume > 0.001 {
            isMuted = false
        }
    }

    func setMuted(_ muted: Bool) {
        setMutedCalls.append(muted)
        isMuted = muted
    }

    func deactivate() {
        if isActive {
            deactivateCount += 1
        }
        isActive = false
        activeTargetUID = nil
    }
}

private final class MockDDCBackend: DDCBackend {
    var isAvailable: Bool = true
    var endpoints: [DDCDisplayEndpoint] = []
    var hardwareVolumes: [Int: Int] = [:]
    var hardwareBrightness: [Int: Int] = [:]
    var hardwareCapabilities: [Int: DDCCapabilities] = [:]
    var hardwareInputs: [Int: DDCInputReadResult] = [:]
    var setVolumeCalls: [(index: Int, volume: Int)] = []
    var setBrightnessCalls: [(index: Int, brightness: Int)] = []
    var setMuteCalls: [(index: Int, muted: Bool)] = []
    var setInputCalls: [(index: Int, source: DisplayInputSource, mode: InputSourceProtocolMode, hint: DDCDisplayHint)] = []
    var readInputHints: [Int: DDCDisplayHint] = [:]
    var writeRawInputCalls: [(index: Int, code: DDCInputCode)] = []
    var probeCalls: [Int] = []
    var muteSupported: Bool = true

    func listEndpoints() -> [DDCDisplayEndpoint] {
        endpoints
    }

    func probeCapabilities(endpointIndex: Int) -> DDCCapabilities {
        probeCalls.append(endpointIndex)
        if let configured = hardwareCapabilities[endpointIndex] {
            return configured
        }
        return DDCCapabilities(
            isReachable: true,
            supportsBrightness: true,
            supportsVolume: true,
            supportedInputs: nil,
            rawCapabilitiesString: nil
        )
    }

    func readBrightness(endpointIndex: Int) -> Int? {
        hardwareBrightness[endpointIndex]
    }

    func setBrightness(_ brightness: Int, endpointIndex: Int) -> Bool {
        setBrightnessCalls.append((endpointIndex, brightness))
        hardwareBrightness[endpointIndex] = brightness
        return true
    }

    func readVolume(endpointIndex: Int) -> Int? {
        hardwareVolumes[endpointIndex]
    }

    func setVolume(_ volume: Int, endpointIndex: Int) -> Bool {
        setVolumeCalls.append((endpointIndex, volume))
        hardwareVolumes[endpointIndex] = volume
        return true
    }

    func setMuted(_ muted: Bool, endpointIndex: Int) -> Bool {
        setMuteCalls.append((endpointIndex, muted))
        return muteSupported
    }

    func readInputSource(endpointIndex: Int, hint: DDCDisplayHint) -> DDCInputReadResult {
        readInputHints[endpointIndex] = hint
        return hardwareInputs[endpointIndex] ?? DDCInputReadResult()
    }

    func writeRawInputCode(_ code: DDCInputCode, endpointIndex: Int) -> Bool {
        writeRawInputCalls.append((endpointIndex, code))
        return true
    }

    func setInputSource(
        _ source: DisplayInputSource,
        endpointIndex: Int,
        protocolMode: InputSourceProtocolMode,
        hint: DDCDisplayHint
    ) -> Bool {
        setInputCalls.append((endpointIndex, source, protocolMode, hint))
        return true
    }
}

@Suite("AudioManager Tests")
struct AudioManagerTests {
    @Test("切换音频输出设备并调节 CoreAudio 音量与静音")
    func coreAudioOutputSelectionAndVolume() {
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 10, uid: "builtin", name: "MacBook Pro 扬声器", transport: .builtIn, isDefault: true, supportsCoreAudioVolume: true),
            AudioOutputDevice(id: 20, uid: "usb", name: "USB 桌面音箱", transport: .usb, isDefault: false, supportsCoreAudioVolume: true)
        ]
        audio.volumes = [10: 0.4, 20: 0.7]
        audio.muted = [10: false, 20: false]

        let manager = AudioManager(audioBackend: audio, ddcBackend: MockDDCBackend(), softwareVolume: MockSoftwareVolumeBackend(), store: InMemoryStateStore())

        #expect(manager.selectOutputDevice(id: 20) == true)
        let snap = manager.currentVolumeSnapshot()
        #expect(snap.deviceID == 20)
        #expect(snap.mode == .coreAudio)
        #expect(abs(snap.volume - 0.7) < 0.001)

        #expect(manager.setCurrentVolume(0.85) == true)
        #expect(abs((audio.volumes[20] ?? 0) - 0.85) < 0.001)

        #expect(manager.setCurrentMuted(true) == true)
        #expect(audio.muted[20] == true)
    }

    @Test("HDMI/DP 外接显示器自动桥接 DDC/CI 音量控制")
    func externalDisplayFallsBackToDDCVolumeControl() {
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 10, uid: "builtin", name: "MacBook Pro 扬声器", transport: .builtIn, isDefault: false, supportsCoreAudioVolume: true),
            AudioOutputDevice(id: 30, uid: "lg-dp", name: "LG HDR 4K", transport: .displayPort, isDefault: true, supportsCoreAudioVolume: false)
        ]

        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "LG HDR 4K")
        ]
        ddc.hardwareVolumes = [0: 64]

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: InMemoryStateStore())
        let snap = manager.currentVolumeSnapshot(readHardwareDDC: true)

        #expect(snap.mode == .ddc(ddcIndex: 0, displayName: "LG HDR 4K"))
        #expect(abs(snap.volume - 0.64) < 0.001)

        #expect(manager.setCurrentVolume(0.32) == true)
        #expect(ddc.setVolumeCalls.last?.index == 0)
        #expect(ddc.setVolumeCalls.last?.volume == 32)
    }

    @Test("DDC 静音通过归零 VCP 0x62 实现可逆静音，解除静音时补发 0x8D=2 并恢复原音量")
    func ddcMuteAndUnmuteRestoresPreviousVolumeSafely() {
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 30, uid: "lg-hdmi", name: "LG UltraFine", transport: .hdmi, isDefault: true, supportsCoreAudioVolume: false)
        ]

        let ddc = MockDDCBackend()
        ddc.endpoints = [DDCDisplayEndpoint(index: 0, name: "LG UltraFine")]
        ddc.hardwareVolumes = [0: 55]

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: InMemoryStateStore())
        _ = manager.currentVolumeSnapshot(readHardwareDDC: true)

        // 静音：不发 0x8D=1（避免锁死 LG 固件），直接将 VCP 0x62 置 0
        #expect(manager.setCurrentMuted(true) == true)
        #expect(ddc.setMuteCalls.isEmpty)
        #expect(ddc.setVolumeCalls.last?.volume == 0)

        // 解除静音：先发 0x8D=2 清理可能的硬件静音锁，再恢复到 55
        #expect(manager.setCurrentMuted(false) == true)
        #expect(ddc.setMuteCalls.last?.muted == false)
        #expect(ddc.setVolumeCalls.last?.volume == 55)

        // 再次静音后直接拖动滑块调高音量，也应先发 0x8D=2 再写目标音量
        #expect(manager.setCurrentMuted(true) == true)
        #expect(manager.setCurrentVolume(0.42) == true)
        #expect(ddc.setMuteCalls.last?.muted == false)
        #expect(ddc.setVolumeCalls.last?.volume == 42)
    }

    @Test("USB/扩展坞上报的外接屏音频设备自动兜底匹配 DDC 并支持手动切换绑定")
    func usbExternalDisplayAudioFallbackAndManualBinding() {
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 40, uid: "dock-lg", name: "USB-C Dock Audio", transport: .usb, isDefault: true, supportsCoreAudioVolume: false)
        ]

        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "LG Left"),
            DDCDisplayEndpoint(index: 1, name: "LG Right")
        ]
        ddc.hardwareVolumes = [0: 30, 1: 80]

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: InMemoryStateStore())
        let initial = manager.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(initial.mode == .ddc(ddcIndex: 0, displayName: "LG Left"))
        #expect(abs(initial.volume - 0.30) < 0.001)

        // 手动改绑到第二台 LG
        manager.bindDDCEndpoint(1, forAudioDeviceUID: "dock-lg")
        let rebound = manager.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(rebound.mode == .ddc(ddcIndex: 1, displayName: "LG Right"))
        #expect(abs(rebound.volume - 0.80) < 0.001)
    }

    @Test("两台同型号 LG 显示器分别选择音频输出时，主音量按 dispext 端口/序号精准对应且绑定持久化")
    func dualIdenticalLGMonitorsMatchCorrectDDCEndpoints() {
        let store = InMemoryStateStore()
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 31, uid: "AppleDP:dispext1:LG", name: "LG HDR 4K", transport: .displayPort, isDefault: false, supportsCoreAudioVolume: false),
            AudioOutputDevice(id: 32, uid: "AppleDP:dispext0:LG", name: "LG HDR 4K", transport: .displayPort, isDefault: true, supportsCoreAudioVolume: false)
        ]

        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "LG HDR 4K", registryPath: "IOService:/.../dispext0/DCPAVServiceProxy"),
            DDCDisplayEndpoint(index: 1, name: "LG HDR 4K", registryPath: "IOService:/.../dispext1/DCPAVServiceProxy")
        ]
        ddc.hardwareVolumes = [0: 25, 1: 75]

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)

        // 当前默认输出是 dispext0（尽管它在数组第 2 位）-> 应精准命中 index 0（音量 25）
        let snap0 = manager.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(snap0.mode == .ddc(ddcIndex: 0, displayName: "LG HDR 4K"))
        #expect(abs(snap0.volume - 0.25) < 0.001)

        // 切换到 dispext1 -> 应精准命中 index 1（音量 75）
        #expect(manager.selectOutputDevice(id: 31) == true)
        let snap1 = manager.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(snap1.mode == .ddc(ddcIndex: 1, displayName: "LG HDR 4K"))
        #expect(abs(snap1.volume - 0.75) < 0.001)

        // 手动改绑后重启（新建 AudioManager 共享同一 store）应记住绑定关系
        manager.bindDDCEndpoint(0, forAudioDeviceUID: "AppleDP:dispext1:LG")
        let restarted = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)
        let afterRestart = restarted.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(afterRestart.mode == .ddc(ddcIndex: 0, displayName: "LG HDR 4K"))
    }

    @Test("切换外接显示器视频输入源（HDMI1/HDMI2/DP1/DP2/USB-C）与 LG 编码映射")
    func switchDisplayInputSource() {
        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "LG HDR 4K"),
            DDCDisplayEndpoint(index: 1, name: "LG HDR 4K")
        ]
        let manager = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: InMemoryStateStore())

        #expect(manager.setDisplayInputSource(.hdmi1, endpointIndex: 0, protocolMode: .auto) == true)
        #expect(manager.setDisplayInputSource(.usbC, endpointIndex: 1, protocolMode: .standard) == true)

        #expect(ddc.setInputCalls.count == 2)
        #expect(ddc.setInputCalls[0].index == 0)
        #expect(ddc.setInputCalls[0].source == .hdmi1)
        #expect(ddc.setInputCalls[0].mode == .auto)
        #expect(ddc.setInputCalls[1].index == 1)
        #expect(ddc.setInputCalls[1].source == .usbC)
        #expect(ddc.setInputCalls[1].mode == .standard)

        // 校验 LG 专有 VCP 0xF4 编码（USB-C 同时覆盖 0xD1 与 0xD2）与标准 MCCS 0x60 编码
        #expect(DisplayInputSource.hdmi1.lgAltCode == 0x90)
        #expect(DisplayInputSource.hdmi2.lgAltCode == 0x91)
        #expect(DisplayInputSource.displayPort1.lgAltCode == 0xD0)
        #expect(DisplayInputSource.displayPort2.lgAltCode == 0xD1)
        #expect(DisplayInputSource.usbC.lgAltCandidateCodes == [0xD1, 0xD2])
        #expect(DisplayInputSource.hdmi1.standardCode == 0x11)
        #expect(DisplayInputSource.displayPort1.standardCode == 0x0F)
    }

    @Test("回读当前硬件输入源、校准 USB-C 自定义硬件码并精准下发")
    func readAndCalibrateUSBCCode() throws {
        let store = InMemoryStateStore()
        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "LG HDR 4K", serialNumber: "SN-LG-LEFT"),
            DDCDisplayEndpoint(index: 1, name: "LG HDR 4K", serialNumber: "SN-LG-RIGHT")
        ]
        // 模拟一台把 USB-C 映射在非常规码 0x60=0x10 的显示器
        ddc.hardwareInputs = [
            0: DDCInputReadResult(standardValue: 0x10, lgAltValue: nil),
            1: DDCInputReadResult(standardValue: nil, lgAltValue: 0xD1)
        ]

        let manager = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)

        // 右屏 0xF4=0xD1 应自动识别为 USB-C
        let rightStatus = manager.readDisplayInputStatus(endpointIndex: 1)
        #expect(rightStatus.activeSource == .usbC)

        // 左屏校准当前端口（0x60=0x10）为 USB-C
        let calibrated = try #require(manager.calibrateCurrentInputSource(as: .usbC, endpointIndex: 0))
        #expect(calibrated == DDCInputCode(dataAddress: 0x51, vcpCode: 0x60, value: 0x10))

        // 重启后再次切换左屏到 USB-C，应精准直发已校准的 raw code (0x60=0x10)
        let restarted = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)
        #expect(restarted.setDisplayInputSource(.usbC, endpointIndex: 0, protocolMode: .auto) == true)
        #expect(ddc.writeRawInputCalls.last?.index == 0)
        #expect(ddc.writeRawInputCalls.last?.code == calibrated)

        // 序列号精准匹配 DisplayInfo -> DDCDisplayEndpoint
        let displays = [
            DisplayInfo(id: 2, uuid: "u-left", serialNumber: "SN-LG-LEFT", name: "左 LG", systemName: "LG HDR 4K", isBuiltin: false, isActive: true, isOnline: true, width: 3840, height: 2160),
            DisplayInfo(id: 3, uuid: "u-right", serialNumber: "SN-LG-RIGHT", name: "右 LG", systemName: "LG HDR 4K", isBuiltin: false, isActive: true, isOnline: true, width: 3840, height: 2160)
        ]
        #expect(restarted.matchDDCEndpoint(for: displays[0], allDisplays: displays)?.index == 0)
        #expect(restarted.matchDDCEndpoint(for: displays[1], allDisplays: displays)?.index == 1)
    }

    @Test("双同型号 LG 通过数字 EDID 序列号精确匹配，自定义改名与镜像态绝不导致 DDC 通道错位")
    func dualIdenticalLGMatchesByNumericSerialRegardlessOfCustomNameOrder() {
        let store = InMemoryStateStore()
        let ddc = MockDDCBackend()
        // IOKit 端点：index 0 是数字序列号 222222（字母串 SN-RIGHT），index 1 是 111111（字母串 SN-CENTER）
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "LG HDR 4K", serialNumber: "SN-RIGHT", numericSerial: 222222),
            DDCDisplayEndpoint(index: 1, name: "LG HDR 4K", serialNumber: "SN-CENTER", numericSerial: 111111)
        ]

        // CoreGraphics 往往只拿到数字序列号，且用户起自定义中文名后顺序与 IOKit 相反，甚至其中一台在镜像中
        let centerDisplay = DisplayInfo(
            id: 10,
            uuid: "u-center",
            serialNumber: "111111",
            numericSerial: 111111,
            name: "中间屏",
            systemName: "LG HDR 4K",
            customName: "中间屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            originX: 0,
            width: 3840,
            height: 2160,
            isMain: true
        )
        let rightDisplay = DisplayInfo(
            id: 20,
            uuid: "u-right",
            serialNumber: "222222",
            numericSerial: 222222,
            name: "右屏",
            systemName: "LG HDR 4K",
            customName: "右屏",
            isBuiltin: false,
            isActive: false,
            isOnline: true,
            originX: 3840,
            width: 3840,
            height: 2160,
            isMain: false,
            mirrorMasterID: 10,
            usageMode: .mirrored(masterID: 10, masterUUID: "u-center", masterName: "中间屏")
        )

        let manager = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)
        let mapping = manager.matchAllDDCEndpoints(for: [centerDisplay, rightDisplay], endpoints: ddc.endpoints)

        // 中间屏 (111111) 必须精准对应 index 1，右屏 (222222，即使在镜像态) 必须精准对应 index 0
        #expect(mapping["u-center"] == 1)
        #expect(mapping["u-right"] == 0)

        // 手动纠偏互换后，重启仍持久记住互换后的绑定关系
        manager.bindDisplay("u-center", toEndpoint: ddc.endpoints[0])
        let restarted = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)
        let reboundMapping = restarted.matchAllDDCEndpoints(for: [centerDisplay, rightDisplay], endpoints: ddc.endpoints)
        #expect(reboundMapping["u-center"] == 0)
        #expect(reboundMapping["u-right"] == 1)
    }

    @Test("真实双 LG UltraFine 硬件拓扑回归测试：dispext0/1 管线与 CoreAudio EDID UID 100% 一对一精准对齐")
    func realDualLGUltraFineHardwareTopologyAlignment() {
        let store = InMemoryStateStore()

        // 模拟本机真实捕获数据：
        // id=2（右屏，主屏）-> vendor=7789(0x1E6D), model=23709(0x5C9D -> 小端 9D5C), dispext1
        // id=3（中屏，左侧）-> vendor=7789(0x1E6D), model=23741(0x5CBD -> 小端 BD5C), dispext0
        let rightDisplay = DisplayInfo(
            id: 2,
            uuid: "uuid-right",
            serialNumber: "651685",
            numericSerial: 651685,
            vendorID: 7789,
            modelID: 23709,
            displayPortToken: "dispext1",
            name: "右屏",
            systemName: "LG ULTRAFINE",
            customName: "右屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            originX: 0,
            width: 1920,
            height: 1080,
            isMain: true
        )
        let centerDisplay = DisplayInfo(
            id: 3,
            uuid: "uuid-center",
            serialNumber: "508957",
            numericSerial: 508957,
            vendorID: 7789,
            modelID: 23741,
            displayPortToken: "dispext0",
            name: "中屏",
            systemName: "LG ULTRAFINE",
            customName: "中屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            originX: -1920,
            width: 1920,
            height: 1080,
            isMain: false
        )

        // IOKit DCPAVServiceProxy 无 ProductAttributes，仅有 dispext0 / dispext1 路径！
        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(
                index: 0,
                name: "外接显示器 #1",
                registryPath: "IOService:/.../dispext0:dcpav-service-epic:0/DCPAVServiceProxy"
            ),
            DDCDisplayEndpoint(
                index: 1,
                name: "外接显示器 #2",
                registryPath: "IOService:/.../dispext1:dcpav-service-epic:0/DCPAVServiceProxy"
            )
        ]
        ddc.hardwareVolumes = [0: 40, 1: 37]

        // CoreAudio 真实设备：
        // id=101 -> 1E6D9D5C-... (HDMI -> model 23709 -> 右屏 -> dispext1 -> DDC[1])
        // id=86  -> 1E6DBD5C-... (DP   -> model 23741 -> 中屏 -> dispext0 -> DDC[0])
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 101, uid: "1E6D9D5C-0000-0000-0A23-010380462878", name: "LG ULTRAFINE", transport: .hdmi, isDefault: false, supportsCoreAudioVolume: false),
            AudioOutputDevice(id: 86, uid: "1E6DBD5C-0000-0000-0A24-0104B53C2278", name: "LG ULTRAFINE", transport: .displayPort, isDefault: true, supportsCoreAudioVolume: false)
        ]

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)
        manager.updateKnownDisplays([centerDisplay, rightDisplay])

        // 1. Display -> DDC：中屏(dispext0) 必须对应 DDC[0]，右屏(dispext1) 必须对应 DDC[1]
        let displayMap = manager.matchAllDDCEndpoints(for: [centerDisplay, rightDisplay], endpoints: ddc.endpoints)
        #expect(displayMap["uuid-center"] == 0)
        #expect(displayMap["uuid-right"] == 1)

        // 2. Audio -> DDC：Audio 86 (BD5C=中屏) 必须对应 DDC[0]，Audio 101 (9D5C=右屏) 必须对应 DDC[1]，绝不撞车！
        let audioMap = manager.matchAllAudioToDDCEndpoints(audioDevices: audio.devices, displays: [centerDisplay, rightDisplay], endpoints: ddc.endpoints)
        #expect(audioMap[86] == 0)
        #expect(audioMap[101] == 1)

        // 3. 当前默认输出是 Audio 86（中屏）-> 主音量必须是 DDC[0] (40%)；切到 Audio 101（右屏）-> 主音量必须是 DDC[1] (37%)
        let snapCenter = manager.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(snapCenter.mode == .ddc(ddcIndex: 0, displayName: "外接显示器 #1"))
        #expect(abs(snapCenter.volume - 0.40) < 0.001)

        #expect(manager.selectOutputDevice(id: 101) == true)
        let snapRight = manager.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(snapRight.mode == .ddc(ddcIndex: 1, displayName: "外接显示器 #2"))
        #expect(abs(snapRight.volume - 0.37) < 0.001)
    }

    @Test("真实 DELL U2718Q MCCS Capabilities (0xF3) 字符串解析：识别支持亮度与三路输入口，但无 VCP 0x62 音量")
    func parseRealDellU2718QMCCSCapabilities() throws {
        let dellRaw = "(prot(monitor)type(lcd)model(U2718Q)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(04 05 06 08 09 0B 0C) 16 18 1A 52 60( 11 0F 10) AA(01  02 03 04) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 03 05) DF E0 E1 E2(00 02 04 0C 0D 0F 10 11 13 14 1D) F0(00 0C) F1 F2 FD)mccs_ver(2.1)mswhql(1))"
        let dellCaps = try #require(DDCCapabilities.parse(capabilitiesString: dellRaw))

        #expect(dellCaps.isReachable == true)
        #expect(dellCaps.supportsBrightness == true)
        #expect(dellCaps.supportsVolume == false)
        #expect(dellCaps.supportedInputs == [.hdmi1, .displayPort1, .displayPort2])

        let lgRaw = "(prot(monitor)type(lcd)model(LG ULTRAFINE)vcp(10 12 60(11 12 0F 1B) 62 8D(01 02) D6))"
        let lgCaps = try #require(DDCCapabilities.parse(capabilitiesString: lgRaw))
        #expect(lgCaps.isReachable == true)
        #expect(lgCaps.supportsBrightness == true)
        #expect(lgCaps.supportsVolume == true)
        #expect(lgCaps.supportedInputs == [.hdmi1, .hdmi2, .displayPort1, .usbC])
    }

    @Test("三档音量策略：CoreAudio -> 支持 0x62 的 DDC -> 免驱动软件音量（Dell U2718Q / EIZO 自动接管与释放）")
    func threeTierVolumeRoutingWithSoftwareVolumeFallback() {
        let store = InMemoryStateStore()
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 1, uid: "builtin-spk", name: "MacBook Pro 扬声器", transport: .builtIn, isDefault: true, supportsCoreAudioVolume: true),
            AudioOutputDevice(id: 2, uid: "1E6D9D5C-0000", name: "LG ULTRAFINE", transport: .hdmi, isDefault: false, supportsCoreAudioVolume: false),
            AudioOutputDevice(id: 3, uid: "10ACE9A0-0000", name: "DELL U2718Q", transport: .displayPort, isDefault: false, supportsCoreAudioVolume: false),
            AudioOutputDevice(id: 4, uid: "15C38831-0000", name: "EV3895", transport: .displayPort, isDefault: false, supportsCoreAudioVolume: false)
        ]
        audio.volumes = [1: 0.6]

        let displays = [
            DisplayInfo(id: 10, uuid: "u-lg", vendorID: 0x1E6D, modelID: 0x5C9D, displayPortToken: "dispext0", name: "LG ULTRAFINE", isBuiltin: false, isActive: true, isOnline: true, width: 3840, height: 2160),
            DisplayInfo(id: 11, uuid: "u-dell", vendorID: 0x10AC, modelID: 0xA0E9, displayPortToken: "dispext1", name: "DELL U2718Q", isBuiltin: false, isActive: true, isOnline: true, width: 3840, height: 2160),
            DisplayInfo(id: 12, uuid: "u-eizo", vendorID: 0x15C3, modelID: 0x3188, displayPortToken: "dispext2", name: "EV3895", isBuiltin: false, isActive: true, isOnline: true, width: 3840, height: 1600)
        ]

        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "LG ULTRAFINE", registryPath: "IOService:/.../dispext0/DCPAVServiceProxy"),
            DDCDisplayEndpoint(index: 1, name: "DELL U2718Q", registryPath: "IOService:/.../dispext1/DCPAVServiceProxy"),
            DDCDisplayEndpoint(index: 2, name: "EV3895", registryPath: "IOService:/.../dispext2/DCPAVServiceProxy")
        ]
        ddc.hardwareVolumes = [0: 45]
        ddc.hardwareCapabilities = [
            0: DDCCapabilities(isReachable: true, supportsBrightness: true, supportsVolume: true, supportedInputs: [.hdmi1, .usbC]),
            1: DDCCapabilities(isReachable: true, supportsBrightness: true, supportsVolume: false, supportedInputs: [.hdmi1, .displayPort1, .displayPort2]),
            2: .unreachable
        ]

        let softVol = MockSoftwareVolumeBackend()
        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: softVol, store: store)
        manager.updateKnownDisplays(displays)
        for idx in 0...2 {
            manager.probeCapabilitiesAndBrightness(endpointIndex: idx)
        }

        // 1. 内置扬声器 -> CoreAudio，绝不激活软件音量
        #expect(manager.currentVolumeSnapshot().mode == .coreAudio)
        #expect(softVol.isActive == false)

        // 2. LG (supportsVolume == true) -> DDC 硬件音量，绝不激活软件音量
        #expect(manager.selectOutputDevice(id: 2) == true)
        #expect(manager.currentVolumeSnapshot().mode == .ddc(ddcIndex: 0, displayName: "LG ULTRAFINE"))
        #expect(softVol.isActive == false)

        // 3. Dell U2718Q (supportsVolume == false) -> 自动走 .software，首次调音量才激活 Tap
        #expect(manager.selectOutputDevice(id: 3) == true)
        let dellSnap = manager.currentVolumeSnapshot()
        #expect(dellSnap.mode == .software(deviceName: "DELL U2718Q"))
        #expect(abs(dellSnap.volume - 1.0) < 0.001)
        #expect(softVol.isActive == false)

        #expect(manager.setCurrentVolume(0.42) == true)
        #expect(softVol.isActive == true)
        #expect(softVol.activeTargetUID == "10ACE9A0-0000")
        #expect(abs(softVol.currentVolume - 0.42) < 0.001)

        #expect(manager.setCurrentMuted(true) == true)
        #expect(softVol.isMuted == true)

        // 4. 外部系统直接切到 EIZO (同样走 .software) -> 自动释放 Dell 的旧 Tap，并进入 EIZO 软件音量态
        _ = audio.setDefaultOutputDevice(id: 4)
        let eizoSnap = manager.currentVolumeSnapshot()
        #expect(eizoSnap.mode == .software(deviceName: "EV3895"))
        #expect(softVol.isActive == false)
        #expect(softVol.deactivateCount == 1)

        #expect(manager.setCurrentVolume(0.65) == true)
        #expect(softVol.activeTargetUID == "15C38831-0000")

        // 5. 切回内置扬声器 -> 自动停用软件音量
        #expect(manager.selectOutputDevice(id: 1) == true)
        #expect(manager.currentVolumeSnapshot().mode == .coreAudio)
        #expect(softVol.isActive == false)

        // 6. 关闭软件音量总开关 -> 无硬件音量的设备回退 .unsupported
        manager.isSoftwareVolumeEnabled = false
        #expect(manager.selectOutputDevice(id: 3) == true)
        #expect(manager.currentVolumeSnapshot().mode == .unsupported)
    }

    @Test("外接显示器硬件亮度 (VCP 0x10) 探测缓存与 0~100 限幅写入")
    func ddcHardwareBrightnessReadWriteAndCapabilityCache() {
        let ddc = MockDDCBackend()
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "DELL U2718Q", registryPath: "IOService:/.../dispext1/DCPAVServiceProxy")
        ]
        ddc.hardwareBrightness = [0: 72]
        ddc.hardwareCapabilities = [
            0: DDCCapabilities(isReachable: true, supportsBrightness: true, supportsVolume: false, supportedInputs: [.hdmi1, .displayPort1, .displayPort2])
        ]

        let manager = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: InMemoryStateStore())

        // 首次探测读取 capabilities + brightness 并缓存
        let caps1 = manager.probeCapabilitiesAndBrightness(endpointIndex: 0)
        #expect(caps1.supportsBrightness == true)
        #expect(caps1.supportsVolume == false)
        #expect(ddc.probeCalls == [0])

        let listed = manager.listDDCEndpoints()
        #expect(listed.first?.currentBrightness == 72)
        #expect(listed.first?.capabilities == caps1)

        // 第二次非强制探测命中缓存，不再重复 I2C 探测 Capabilities
        _ = manager.probeCapabilitiesAndBrightness(endpointIndex: 0, force: false)
        #expect(ddc.probeCalls == [0])

        // 写入亮度并校验 0...100 边界限幅
        #expect(manager.setDDCBrightness(120, endpointIndex: 0) == true)
        #expect(ddc.setBrightnessCalls.last?.brightness == 100)
        #expect(manager.setDDCBrightness(-10, endpointIndex: 0) == true)
        #expect(ddc.setBrightnessCalls.last?.brightness == 0)
        #expect(manager.readDDCBrightness(endpointIndex: 0) == 0)
    }

    @Test("Apple Silicon 右屏 LG UltraFine 回归：即使 IOKit 端点无 LG 名称，仍通过 0x1E6D VendorID 识别 LG，且中屏切走导致 dispext 偏移时不丢配置")
    func rightScreenLGUltraFineHintAndDynamicDispExtShiftResilience() {
        let store = InMemoryStateStore()
        let ddc = MockDDCBackend()

        // 初始双外接屏同时在线：中屏在 dispext0 (index 0)，右屏在 dispext1 (index 1)，IOKit 均无品牌名
        ddc.endpoints = [
            DDCDisplayEndpoint(
                index: 0,
                name: "外接显示器 #1",
                registryPath: "IOService:/.../dispext0:dcpav-service-epic:0/DCPAVServiceProxy"
            ),
            DDCDisplayEndpoint(
                index: 1,
                name: "外接显示器 #2",
                registryPath: "IOService:/.../dispext1:dcpav-service-epic:0/DCPAVServiceProxy"
            )
        ]

        let centerDisplay = DisplayInfo(
            id: 3,
            uuid: "E7ED1E57-B93B-4D73-9864-BCCD389B3D4D",
            serialNumber: "508957",
            numericSerial: 508957,
            vendorID: 0x1E6D,
            modelID: 0x5CBD,
            displayPortToken: "dispext0",
            name: "中屏",
            systemName: "LG ULTRAFINE",
            customName: "中屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            originX: 0,
            width: 1920,
            height: 1080,
            isMain: true
        )
        let rightDisplayOnExt1 = DisplayInfo(
            id: 2,
            uuid: "70AA4EEE-E3C1-4449-9DDD-E6346A6566D9",
            serialNumber: "651685",
            numericSerial: 651685,
            vendorID: 0x1E6D,
            modelID: 0x5C9D,
            displayPortToken: "dispext1",
            name: "右屏",
            systemName: "LG ULTRAFINE",
            customName: "右屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            originX: 1920,
            width: 1920,
            height: 1080,
            isMain: false
        )

        let manager = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, softwareVolume: MockSoftwareVolumeBackend(), store: store)
        manager.updateKnownDisplays([centerDisplay, rightDisplayOnExt1])

        // 1. 切换右屏输入源 -> 必须命中 index 1，且将 hint.isLG == true (vendor 0x1E6D) 透传给 DDCBackend，不再误判为非 LG
        #expect(manager.setDisplayInputSource(.hdmi2, endpointIndex: 1, protocolMode: .auto, displayUUID: rightDisplayOnExt1.uuid) == true)
        #expect(ddc.setInputCalls.last?.index == 1)
        #expect(ddc.setInputCalls.last?.source == .hdmi2)
        #expect(ddc.setInputCalls.last?.mode == .auto)
        #expect(ddc.setInputCalls.last?.hint.isLG == true)
        #expect(ddc.setInputCalls.last?.hint.vendorID == 0x1E6D)

        // 2. 为右屏设置独立协议覆盖（如强制 LG 0xF4）并为 USB-C 手动绑定 0xF4=0xD1
        manager.setDisplayInputProtocol(.lgAlt, forDisplayUUID: rightDisplayOnExt1.uuid)
        let manualUSBCCode = DDCInputCode(dataAddress: 0x50, vcpCode: 0xF4, value: 0xD1)
        manager.setManualInputCode(manualUSBCCode, for: .usbC, endpointIndex: 1, displayUUID: rightDisplayOnExt1.uuid)

        // 3. 模拟「中屏」切走到另一台主机后断开：右屏在 macOS 中自动漂移为 dispext0 (index 0)！
        //    即便 UI 调用方仍传入旧的 endpointIndex = 1，通过 displayUUID 也应动态重定位到最新 index 0，且保留右屏专属协议与端口编码！
        ddc.endpoints = [
            DDCDisplayEndpoint(
                index: 0,
                name: "外接显示器 #1",
                registryPath: "IOService:/.../dispext0:dcpav-service-epic:0/DCPAVServiceProxy"
            )
        ]
        let rightDisplayShiftedToExt0 = DisplayInfo(
            id: 2,
            uuid: rightDisplayOnExt1.uuid,
            serialNumber: "651685",
            numericSerial: 651685,
            vendorID: 0x1E6D,
            modelID: 0x5C9D,
            displayPortToken: "dispext0",
            name: "右屏",
            systemName: "LG ULTRAFINE",
            customName: "右屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            originX: 1512,
            width: 1920,
            height: 1080,
            isMain: false
        )
        manager.updateKnownDisplays([rightDisplayShiftedToExt0])

        // 切右屏 DP1（未单独绑码，但该屏覆盖为 .lgAlt，即便全局传 .standard 也应走右屏专属 .lgAlt 且命中新 index 0）
        #expect(manager.setDisplayInputSource(.displayPort1, endpointIndex: 1, protocolMode: .standard, displayUUID: rightDisplayShiftedToExt0.uuid) == true)
        #expect(ddc.setInputCalls.last?.index == 0)
        #expect(ddc.setInputCalls.last?.mode == .lgAlt)
        #expect(ddc.setInputCalls.last?.hint.isLG == true)

        // 切右屏 USB-C -> 应直接命中之前在 dispext1 时绑定的 0xF4=0xD1，并发往新 index 0
        #expect(manager.setDisplayInputSource(.usbC, endpointIndex: 1, protocolMode: .auto, displayUUID: rightDisplayShiftedToExt0.uuid) == true)
        #expect(ddc.writeRawInputCalls.last?.index == 0)
        #expect(ddc.writeRawInputCalls.last?.code == manualUSBCCode)
    }

    @Test("跨场景零手操回归：实验室 DELL (dispext0) 拔线回家接双 LG (dispext0/1) 时，能力缓存、音量模式与输入源协议全自动隔离切换")
    func labDellToHomeDualLGZeroTouchTransition() throws {
        // 模拟历史遗留脏状态：两台 LG 音频同时指向旧索引 1，且右屏曾被手操绑在旧 port:dispext1
        let dirtyInitial = PersistedAppState(
            audioToDDCBindings: [
                "1E6D9D5C-0000-0000-0A23-010380462878": 1,
                "1E6DBD5C-0000-0000-0A24-0104B53C2278": 1
            ],
            displayToDDCBindings: [
                "70AA4EEE-E3C1-4449-9DDD-E6346A6566D9": "port:dispext1"
            ]
        )
        let store = InMemoryStateStore(initial: dirtyInitial)
        let audio = MockAudioBackend()
        let ddc = MockDDCBackend()
        let softVol = MockSoftwareVolumeBackend()

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, softwareVolume: softVol, store: store)

        // --- 阶段 1：在实验室接 DELL（USB-C 报为 0x19，不支持 0x62 音量，占用 dispext0） ---
        let dellDisplay = DisplayInfo(
            id: 2,
            uuid: "30842DC4-3EFC-4D83-98E6-D8F59FFAA634",
            vendorID: 0x10AC,
            modelID: 0xA0E9,
            displayPortToken: "dispext0",
            name: "DELL U2718Q",
            systemName: "DELL U2718Q",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            width: 3840,
            height: 2160
        )
        let dellCaps = try #require(DDCCapabilities.parse(
            capabilitiesString: "(prot(monitor)type(lcd)model(U2724DE)vcp(10 12 60(11 0F 19) D6))"
        ))
        #expect(dellCaps.supportedInputs == [.hdmi1, .displayPort1, .usbC])
        #expect(dellCaps.supportedInputCodes == [.hdmi1: 0x11, .displayPort1: 0x0F, .usbC: 0x19])

        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "外接显示器 #1", registryPath: "IOService:/.../dispext0/DCPAVServiceProxy")
        ]
        ddc.hardwareCapabilities = [0: dellCaps]
        audio.devices = [
            AudioOutputDevice(id: 50, uid: "10ACE9A0-0000", name: "DELL U2718Q", transport: .displayPort, isDefault: true, supportsCoreAudioVolume: false)
        ]

        manager.updateKnownDisplays([dellDisplay])
        _ = manager.probeCapabilitiesAndBrightness(endpointIndex: 0, displayUUID: dellDisplay.uuid)

        // 实验室 DELL 音量自动走免驱动软件音量，输入源自动携带非 LG 标记与精确 0x19 编码
        #expect(manager.currentVolumeSnapshot().mode == .software(deviceName: "DELL U2718Q"))
        #expect(manager.setDisplayInputSource(.usbC, endpointIndex: 0, protocolMode: .auto, displayUUID: dellDisplay.uuid) == true)
        #expect(ddc.setInputCalls.last?.hint.isLG == false)
        #expect(ddc.setInputCalls.last?.hint.isKnownNonLG == true)
        #expect(ddc.setInputCalls.last?.hint.capabilities?.supportedInputCodes[.usbC] == 0x19)

        // --- 阶段 2：合盖回家，MonitorBlock 常驻不重启，这次先插了「右屏」占用了同一个 dispext0，再插「中屏」占用 dispext1 ---
        let homeRight = DisplayInfo(
            id: 3,
            uuid: "70AA4EEE-E3C1-4449-9DDD-E6346A6566D9",
            serialNumber: "651685",
            numericSerial: 651685,
            vendorID: 0x1E6D,
            modelID: 0x5C9D,
            displayPortToken: "dispext0",
            name: "右屏",
            systemName: "LG ULTRAFINE",
            customName: "右屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            width: 1920,
            height: 1080
        )
        let homeCenter = DisplayInfo(
            id: 4,
            uuid: "E7ED1E57-B93B-4D73-9864-BCCD389B3D4D",
            serialNumber: "508957",
            numericSerial: 508957,
            vendorID: 0x1E6D,
            modelID: 0x5CBD,
            displayPortToken: "dispext1",
            name: "中屏",
            systemName: "LG ULTRAFINE",
            customName: "中屏",
            isBuiltin: false,
            isActive: true,
            isOnline: true,
            width: 1920,
            height: 1080
        )
        ddc.endpoints = [
            DDCDisplayEndpoint(index: 0, name: "外接显示器 #1", registryPath: "IOService:/.../dispext0/DCPAVServiceProxy"),
            DDCDisplayEndpoint(index: 1, name: "外接显示器 #2", registryPath: "IOService:/.../dispext1/DCPAVServiceProxy")
        ]
        ddc.hardwareCapabilities = [
            0: DDCCapabilities(isReachable: true, supportsBrightness: true, supportsVolume: true, supportedInputs: nil),
            1: DDCCapabilities(isReachable: true, supportsBrightness: true, supportsVolume: true, supportedInputs: nil)
        ]
        ddc.hardwareVolumes = [0: 35, 1: 60]
        audio.devices = [
            AudioOutputDevice(id: 101, uid: "1E6D9D5C-0000-0000-0A23-010380462878", name: "LG ULTRAFINE", transport: .hdmi, isDefault: true, supportsCoreAudioVolume: false),
            AudioOutputDevice(id: 86, uid: "1E6DBD5C-0000-0000-0A24-0104B53C2278", name: "LG ULTRAFINE", transport: .displayPort, isDefault: false, supportsCoreAudioVolume: false)
        ]

        manager.updateKnownDisplays([homeRight, homeCenter])
        let homeMap = manager.matchAllDDCEndpoints(for: [homeRight, homeCenter], endpoints: ddc.endpoints)

        // 即使历史残留了 "port:dispext1"，物理管线 dispext0 仍优先锁定 index 0（绝不错控到中屏！）
        #expect(homeMap[homeRight.uuid] == 0)
        #expect(homeMap[homeCenter.uuid] == 1)

        // 右屏占用了实验室 DELL 刚用过的 dispext0，但能力探测绝不命中 DELL 缓存，音量自动切回右屏 DDC[0] (35%)
        let rightCaps = manager.probeCapabilitiesAndBrightness(endpointIndex: 0, displayUUID: homeRight.uuid)
        #expect(rightCaps.supportsVolume == true)
        #expect(rightCaps.supportedInputs == nil)

        let homeVol = manager.currentVolumeSnapshot(readHardwareDDC: true)
        #expect(homeVol.mode == .ddc(ddcIndex: 0, displayName: "外接显示器 #1"))
        #expect(abs(homeVol.volume - 0.35) < 0.001)

        // 切右屏输入源 -> 自动识别 LG (0x1E6D) 并发往 index 0
        #expect(manager.setDisplayInputSource(.hdmi2, endpointIndex: 0, protocolMode: .auto, displayUUID: homeRight.uuid) == true)
        #expect(ddc.setInputCalls.last?.index == 0)
        #expect(ddc.setInputCalls.last?.hint.isLG == true)
    }
}
