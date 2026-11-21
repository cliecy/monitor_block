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

        let manager = AudioManager(audioBackend: audio, ddcBackend: MockDDCBackend())

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

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc)
        let snap = manager.currentVolumeSnapshot(readHardwareDDC: true)

        #expect(snap.mode == .ddc(ddcIndex: 0, displayName: "LG HDR 4K"))
        #expect(abs(snap.volume - 0.64) < 0.001)

        #expect(manager.setCurrentVolume(0.32) == true)
        #expect(ddc.setVolumeCalls.last?.index == 0)
        #expect(ddc.setVolumeCalls.last?.volume == 32)
    }

    @Test("外接屏不支持 DDC VCP 0x8D 静音码时自动回退为将音量设为 0 与恢复原音量")
    func ddcMuteFallsBackToZeroVolumeWhenVCP8DUnsupported() {
        let audio = MockAudioBackend()
        audio.devices = [
            AudioOutputDevice(id: 30, uid: "lg-hdmi", name: "LG UltraFine", transport: .hdmi, isDefault: true, supportsCoreAudioVolume: false)
        ]

        let ddc = MockDDCBackend()
        ddc.endpoints = [DDCDisplayEndpoint(index: 0, name: "LG UltraFine")]
        ddc.hardwareVolumes = [0: 55]
        ddc.muteSupported = false

        let manager = AudioManager(audioBackend: audio, ddcBackend: ddc)
        _ = manager.currentVolumeSnapshot(readHardwareDDC: true)

        #expect(manager.setCurrentMuted(true) == true)
        #expect(ddc.setVolumeCalls.last?.volume == 0)

        #expect(manager.setCurrentMuted(false) == true)
        #expect(ddc.setVolumeCalls.last?.volume == 55)
    }
}
