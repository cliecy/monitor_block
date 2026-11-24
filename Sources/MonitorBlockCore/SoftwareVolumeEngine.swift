import AudioToolbox
import CoreAudio
import Darwin
import Foundation

public enum SoftwareVolumeError: Error, LocalizedError, Equatable, Sendable {
    case osVersionNotSupported
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .osVersionNotSupported:
            return "免驱动软件音量需要 macOS 14.2 及以上系统。"
        case .tapCreationFailed(let status):
            return "启动软件音量失败（错误码 \(status)），请在「系统设置 → 隐私与安全性 → 仅系统音频录制」中允许 MonitorBlock。"
        case .aggregateCreationFailed(let status):
            return "创建私有音频转发设备失败（错误码 \(status)）。"
        case .ioProcFailed(let status):
            return "启动软件音量音频处理回调失败（错误码 \(status)）。"
        }
    }
}

public protocol SoftwareVolumeBackend: AnyObject {
    var isSupported: Bool { get }
    var isActive: Bool { get }
    var activeTargetUID: String? { get }
    var currentVolume: Double { get }
    var isMuted: Bool { get }
    var lastError: String? { get }

    func activate(targetDeviceUID: String, volume: Double, muted: Bool) throws
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    func deactivate()
}

/// 线程安全的实时音频增益状态盒（供 CoreAudio 实时 IOProc 线程零锁/低开销读取并做防爆音平滑插值）
private final class RealtimeGainBox: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var targetGain: Float = 1.0
    private var currentGain: Float = 1.0

    func set(volume: Double, muted: Bool) {
        let clamped = min(max(volume, 0.0), 1.0)
        // 采用 1.5 次方感知曲线，低音量段调节更细腻自然
        let perceptual: Float = muted ? 0.0 : Float(pow(clamped, 1.5))
        os_unfair_lock_lock(&lock)
        targetGain = perceptual
        os_unfair_lock_unlock(&lock)
    }

    func reset(volume: Double, muted: Bool) {
        let clamped = min(max(volume, 0.0), 1.0)
        let perceptual: Float = muted ? 0.0 : Float(pow(clamped, 1.5))
        os_unfair_lock_lock(&lock)
        targetGain = perceptual
        currentGain = perceptual
        os_unfair_lock_unlock(&lock)
    }

    /// 对输入缓冲区乘以平滑增益后写入输出缓冲区
    func process(
        inBufferList: UnsafePointer<AudioBufferList>?,
        outBufferList: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let inBufferList, let outBufferList else { return }

        os_unfair_lock_lock(&lock)
        let target = targetGain
        var current = currentGain
        os_unfair_lock_unlock(&lock)

        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inBufferList))
        let outBuffers = UnsafeMutableAudioBufferListPointer(outBufferList)
        guard !outBuffers.isEmpty else { return }

        // 先清零所有输出，防止无输入时残留噪声
        for i in 0..<outBuffers.count {
            if let data = outBuffers[i].mData {
                memset(data, 0, Int(outBuffers[i].mDataByteSize))
            }
        }

        // 统一做极快一阶平滑，消除拉动滑块时的咔哒声（每帧步进保证左右声道完全平衡）
        let smoothing: Float = 0.015

        // Case 1: 缓冲区数量与通道布局完全一致（最常见：同为 interleaved 或同为 non-interleaved）
        if inBuffers.count == outBuffers.count {
            let bufferCount = inBuffers.count
            for idx in 0..<bufferCount {
                guard let inRaw = inBuffers[idx].mData,
                      let outRaw = outBuffers[idx].mData else { continue }
                let inCh = max(Int(inBuffers[idx].mNumberChannels), 1)
                let outCh = max(Int(outBuffers[idx].mNumberChannels), 1)
                let inFrames = Int(inBuffers[idx].mDataByteSize) / (MemoryLayout<Float>.size * inCh)
                let outFrames = Int(outBuffers[idx].mDataByteSize) / (MemoryLayout<Float>.size * outCh)
                let frames = min(inFrames, outFrames)
                guard frames > 0 else { continue }

                let inSamples = inRaw.assumingMemoryBound(to: Float.self)
                let outSamples = outRaw.assumingMemoryBound(to: Float.self)
                let copyCh = min(inCh, outCh)

                var localGain = current
                for f in 0..<frames {
                    localGain += (target - localGain) * smoothing
                    let inBase = f * inCh
                    let outBase = f * outCh
                    for c in 0..<copyCh {
                        outSamples[outBase + c] = inSamples[inBase + c] * localGain
                    }
                }
                if idx == bufferCount - 1 {
                    current = localGain
                }
            }
        } else if inBuffers.count == 1 && outBuffers.count >= 2 {
            // Case 2: 输入为 interleaved 多声道，输出为 non-interleaved 分离声道
            if let inRaw = inBuffers[0].mData {
                let inCh = max(Int(inBuffers[0].mNumberChannels), 1)
                let inFrames = Int(inBuffers[0].mDataByteSize) / (MemoryLayout<Float>.size * inCh)
                let outFrames = Int(outBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
                let frames = min(inFrames, outFrames)
                let inSamples = inRaw.assumingMemoryBound(to: Float.self)
                let copyCh = min(inCh, outBuffers.count)

                var localGain = current
                for f in 0..<frames {
                    localGain += (target - localGain) * smoothing
                    for c in 0..<copyCh {
                        if let outRaw = outBuffers[c].mData {
                            let outSamples = outRaw.assumingMemoryBound(to: Float.self)
                            outSamples[f] = inSamples[f * inCh + c] * localGain
                        }
                    }
                }
                current = localGain
            }
        } else if inBuffers.count >= 2 && outBuffers.count == 1 {
            // Case 3: 输入为 non-interleaved 分离声道，输出为 interleaved 多声道
            if let outRaw = outBuffers[0].mData {
                let outCh = max(Int(outBuffers[0].mNumberChannels), 1)
                let inFrames = Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
                let outFrames = Int(outBuffers[0].mDataByteSize) / (MemoryLayout<Float>.size * outCh)
                let frames = min(inFrames, outFrames)
                let outSamples = outRaw.assumingMemoryBound(to: Float.self)
                let copyCh = min(inBuffers.count, outCh)

                var localGain = current
                for f in 0..<frames {
                    localGain += (target - localGain) * smoothing
                    for c in 0..<copyCh {
                        if let inRaw = inBuffers[c].mData {
                            let inSamples = inRaw.assumingMemoryBound(to: Float.self)
                            outSamples[f * outCh + c] = inSamples[f] * localGain
                        }
                    }
                }
                current = localGain
            }
        }

        os_unfair_lock_lock(&lock)
        currentGain = current
        os_unfair_lock_unlock(&lock)
    }
}

/// 基于 macOS 14.2+ CoreAudio Process Tap + 私有 Aggregate Device 的免驱动软件音量引擎
public final class CoreAudioProcessTapVolumeEngine: SoftwareVolumeBackend {
    private let stateLock = NSLock()
    private let gainBox = RealtimeGainBox()

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var _targetUID: String?
    private var _volume: Double = 0.7
    private var _muted: Bool = false
    private var _lastError: String?

    public var isSupported: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    public var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) && ioProcID != nil
    }

    public var activeTargetUID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _targetUID
    }

    public var currentVolume: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _volume
    }

    public var isMuted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _muted
    }

    public var lastError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastError
    }

    public init() {}

    deinit {
        deactivate()
    }

    public func activate(targetDeviceUID: String, volume: Double, muted: Bool) throws {
        guard #available(macOS 14.2, *) else {
            throw SoftwareVolumeError.osVersionNotSupported
        }

        stateLock.lock()
        let alreadyActiveOnSameTarget = (aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) && ioProcID != nil && _targetUID == targetDeviceUID)
        stateLock.unlock()

        if alreadyActiveOnSameTarget {
            setVolume(volume)
            setMuted(muted)
            return
        }

        deactivate()

        let clampedVol = min(max(volume, 0.0), 1.0)
        gainBox.reset(volume: clampedVol, muted: muted)

        do {
            try startTapAndAggregate(targetDeviceUID: targetDeviceUID)
            stateLock.lock()
            _targetUID = targetDeviceUID
            _volume = clampedVol
            _muted = muted
            _lastError = nil
            stateLock.unlock()
        } catch {
            deactivate()
            stateLock.lock()
            _lastError = error.localizedDescription
            stateLock.unlock()
            throw error
        }
    }

    public func setVolume(_ volume: Double) {
        let clamped = min(max(volume, 0.0), 1.0)
        stateLock.lock()
        _volume = clamped
        if clamped > 0.001 && _muted {
            _muted = false
        }
        let mutedNow = _muted
        stateLock.unlock()
        gainBox.set(volume: clamped, muted: mutedNow)
    }

    public func setMuted(_ muted: Bool) {
        stateLock.lock()
        _muted = muted
        let volNow = _volume
        stateLock.unlock()
        gainBox.set(volume: volNow, muted: muted)
    }

    public func deactivate() {
        stateLock.lock()
        let aggID = aggregateDeviceID
        let proc = ioProcID
        let currentTap = tapID
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        _targetUID = nil
        stateLock.unlock()

        if aggID != AudioObjectID(kAudioObjectUnknown), let proc {
            _ = AudioDeviceStop(aggID, proc)
            _ = AudioDeviceDestroyIOProcID(aggID, proc)
        }
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggID)
        }
        if #available(macOS 14.2, *), currentTap != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(currentTap)
        }
    }

    // MARK: - Private CoreAudio Tap Setup

    @available(macOS 14.2, *)
    private func startTapAndAggregate(targetDeviceUID: String) throws {
        // 1. 尝试查找自身进程的 CoreAudio Process ObjectID，避免回环
        var excludedProcesses: [AudioObjectID] = []
        if let selfProcessObj = currentProcessAudioObjectID() {
            excludedProcesses.append(selfProcessObj)
        }

        // 2. 优先创建定向到目标 HDMI/DP 设备流 0 的 Tap（仅截取发往该外接屏的音频，且格式自动与硬件流一致）；
        //    若部分设备不支持定向流，再回退为全局立体声 Tap。
        let primaryDesc = CATapDescription(
            excludingProcesses: excludedProcesses,
            deviceUID: targetDeviceUID,
            stream: 0
        )
        configureTapDescription(primaryDesc)

        var activeTapDesc = primaryDesc
        var createdTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var tapStatus = AudioHardwareCreateProcessTap(primaryDesc, &createdTapID)

        if tapStatus != noErr || createdTapID == AudioObjectID(kAudioObjectUnknown) {
            let fallbackDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
            configureTapDescription(fallbackDesc)
            createdTapID = AudioObjectID(kAudioObjectUnknown)
            let fallbackStatus = AudioHardwareCreateProcessTap(fallbackDesc, &createdTapID)
            if fallbackStatus == noErr, createdTapID != AudioObjectID(kAudioObjectUnknown) {
                activeTapDesc = fallbackDesc
                tapStatus = fallbackStatus
            } else {
                throw SoftwareVolumeError.tapCreationFailed(tapStatus)
            }
        }

        stateLock.lock()
        tapID = createdTapID
        stateLock.unlock()

        // 3. 创建私有 Aggregate Device，将 Tap 作为输入、物理外接屏作为输出与主时钟
        let tapUUID = activeTapDesc.uuid.uuidString
        let aggUID = "local.cliecy.MonitorBlock.SoftVol.\(UUID().uuidString)"
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MonitorBlock Soft Volume",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: targetDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: targetDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: targetDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var createdAggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &createdAggID)
        guard aggStatus == noErr, createdAggID != AudioObjectID(kAudioObjectUnknown) else {
            throw SoftwareVolumeError.aggregateCreationFailed(aggStatus)
        }

        stateLock.lock()
        aggregateDeviceID = createdAggID
        stateLock.unlock()

        // 4. 注册 IOProc 实时对采样乘以增益并写入物理 HDMI/DP 输出
        let box = gainBox
        var createdProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&createdProcID, createdAggID, nil) { _, inInputData, _, outOutputData, _ in
            box.process(inBufferList: inInputData, outBufferList: outOutputData)
        }
        guard procStatus == noErr, let createdProcID else {
            throw SoftwareVolumeError.ioProcFailed(procStatus)
        }

        // 若创建 Tap 时自身尚未注册 CoreAudio ProcessObject，在建好 IOProc 后补齐自排除，杜绝自环路
        if excludedProcesses.isEmpty, let selfProcessObj = currentProcessAudioObjectID() {
            activeTapDesc.processes = [selfProcessObj]
            var tapDescRef: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(activeTapDesc)
            var descAddr = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyDescription,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectSetPropertyData(
                createdTapID,
                &descAddr,
                0,
                nil,
                UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size),
                &tapDescRef
            )
        }

        stateLock.lock()
        ioProcID = createdProcID
        stateLock.unlock()

        let startStatus = AudioDeviceStart(createdAggID, createdProcID)
        guard startStatus == noErr else {
            throw SoftwareVolumeError.ioProcFailed(startStatus)
        }
    }

    @available(macOS 14.2, *)
    private func configureTapDescription(_ desc: CATapDescription) {
        desc.name = "MonitorBlock Software Volume Tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            desc.bundleIDs = [bundleID]
        }
    }

    private func currentProcessAudioObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObject: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &outSize,
            &processObject
        )
        guard status == noErr, processObject != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return processObject
    }
}
