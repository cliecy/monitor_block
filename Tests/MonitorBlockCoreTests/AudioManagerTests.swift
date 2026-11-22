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

private final class MockDDCBackend: DDCBackend {
    var isAvailable: Bool = true
    var endpoints: [DDCDisplayEndpoint] = []
    var hardwareVolumes: [Int: Int] = [:]
    var setVolumeCalls: [(index: Int, volume: Int)] = []
    var setMuteCalls: [(index: Int, muted: Bool)] = []
    var setInputCalls: [(index: Int, source: DisplayInputSource)] = []
    var muteSupported: Bool = true

    func listEndpoints() -> [DDCDisplayEndpoint] {
        endpoints
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

    func setInputSource(_ source: DisplayInputSource, endpointIndex: Int) -> Bool {
        setInputCalls.append((endpointIndex, source))
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

        let manager = AudioManager(audioBackend: audio, ddcBackend: MockDDCBackend(), store: InMemoryStateStore())

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

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, store: InMemoryStateStore())
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

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, store: InMemoryStateStore())
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

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, store: InMemoryStateStore())
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

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc, store: store)

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
        let restarted = AudioManager(audioBackend: audio, ddcBackend: ddc, store: store)
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
        let manager = AudioManager(audioBackend: MockAudioBackend(), ddcBackend: ddc, store: InMemoryStateStore())

        #expect(manager.setDisplayInputSource(.hdmi1, endpointIndex: 0) == true)
        #expect(manager.setDisplayInputSource(.usbC, endpointIndex: 1) == true)

        #expect(ddc.setInputCalls.count == 2)
        #expect(ddc.setInputCalls[0].index == 0)
        #expect(ddc.setInputCalls[0].source == .hdmi1)
        #expect(ddc.setInputCalls[1].index == 1)
        #expect(ddc.setInputCalls[1].source == .usbC)

        // 校验 LG 专有 VCP 0xF4 编码与标准 MCCS 0x60 编码
        #expect(DisplayInputSource.hdmi1.lgAltCode == 0x90)
        #expect(DisplayInputSource.hdmi2.lgAltCode == 0x91)
        #expect(DisplayInputSource.displayPort1.lgAltCode == 0xD0)
        #expect(DisplayInputSource.displayPort2.lgAltCode == 0xD1)
        #expect(DisplayInputSource.usbC.lgAltCode == 0xD2)
        #expect(DisplayInputSource.hdmi1.standardCode == 0x11)
        #expect(DisplayInputSource.displayPort1.standardCode == 0x0F)
    }
}
