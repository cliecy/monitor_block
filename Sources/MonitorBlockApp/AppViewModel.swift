import AppKit
import CoreGraphics
import Foundation
import MonitorBlockCore

@MainActor
final class AppViewModel: ObservableObject {
    enum PopoverTab: String, CaseIterable, Identifiable {
        case displays = "显示器"
        case audio = "声音"
        case layout = "布局"
        var id: String { rawValue }
    }

    enum MainWindowSection: String, CaseIterable, Identifiable {
        case displays = "显示器管理"
        case arrangement = "排列与预设"
        case disableRules = "关闭后规则"
        case audio = "声音与外接音量"
        case settings = "通用设置"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .displays: return "display.2"
            case .arrangement: return "rectangle.3.group"
            case .disableRules: return "wand.and.stars"
            case .audio: return "speaker.wave.2.fill"
            case .settings: return "gearshape"
            }
        }
    }

    enum RelativeSide {
        case left, right, top, bottom
    }

    // Navigation
    @Published var popoverTab: PopoverTab = .displays
    @Published var mainSection: MainWindowSection = .displays

    // Display & Layout State
    @Published var displays: [DisplayInfo] = []
    @Published var presets: [LayoutPreset] = []
    @Published var livePlacements: [DisplayPlacement] = []
    @Published var selectedLiveUUID: String?
    @Published var newPresetName: String = ""
    @Published var renameDrafts: [String: String] = [:] // display.uuid -> draft text

    // Disable Rule Editor State
    @Published var selectedRuleTargetUUID: String?
    @Published var rulePlacements: [DisplayPlacement] = []
    @Published var selectedRuleItemUUID: String?
    @Published var restorePreviousOnEnable: Bool = true
    @Published var savedRuleUUIDs: Set<String> = []

    // DDC & Input Source State
    @Published var ddcEndpoints: [DDCDisplayEndpoint] = []
    @Published var displayToDDCIndex: [String: Int] = [:]
    @Published var inputStatuses: [Int: DisplayInputStatus] = [:]
    @Published var switchingInputs: [Int: DisplayInputSource] = [:]
    @Published var inputProtocolMode: InputSourceProtocolMode = .auto

    // Audio State
    @Published var audioDevices: [AudioOutputDevice] = []
    @Published var volume: Double = 0.5
    @Published var isMuted: Bool = false
    @Published var volumeMode: VolumeControlMode = .unsupported
    @Published var volumeTargetName: String?
    @Published var ddcVolumes: [Int: Double] = [:]
    @Published var ddcMuted: [Int: Bool] = [:]

    // Preferences & Banner
    @Published var launchAtLoginEnabled: Bool = false
    @Published var autoRestoreOnQuit: Bool = true
    @Published var isPrivateAPIAvailable: Bool = true
    @Published var statusBanner: (text: String, isError: Bool)?

    let liveDragSession = CanvasDragSession()
    let ruleDragSession = CanvasDragSession()

    let displayManager: DisplayManager
    let audioManager: AudioManager
    let launchAtLogin: LaunchAtLoginManager

    private let onOpenMainWindow: (MainWindowSection?) -> Void
    private let onPromptSavePreset: () -> Void
    private let onToggleAutoRestore: () -> Void
    private let onQuit: () -> Void
    private let onStatusChanged: () -> Void

    private static let inputProtocolKey = "MonitorBlock.inputProtocolMode"

    private var pendingVolumeWorkItem: DispatchWorkItem?
    private var pendingDDCWorkItems: [Int: DispatchWorkItem] = [:]
    private var bannerClearWorkItem: DispatchWorkItem?

    init(
        displayManager: DisplayManager,
        audioManager: AudioManager,
        launchAtLogin: LaunchAtLoginManager,
        autoRestoreOnQuit: Bool,
        onOpenMainWindow: @escaping (MainWindowSection?) -> Void,
        onPromptSavePreset: @escaping () -> Void,
        onToggleAutoRestore: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onStatusChanged: @escaping () -> Void
    ) {
        self.displayManager = displayManager
        self.audioManager = audioManager
        self.launchAtLogin = launchAtLogin
        self.autoRestoreOnQuit = autoRestoreOnQuit
        self.onOpenMainWindow = onOpenMainWindow
        self.onPromptSavePreset = onPromptSavePreset
        self.onToggleAutoRestore = onToggleAutoRestore
        self.onQuit = onQuit
        self.onStatusChanged = onStatusChanged

        if let raw = UserDefaults.standard.string(forKey: Self.inputProtocolKey),
           let saved = InputSourceProtocolMode(rawValue: raw) {
            self.inputProtocolMode = saved
        }
        refresh(readHardwareDDC: false)
    }

    // MARK: - Refresh

    func refresh(readHardwareDDC: Bool = false, autoRestoreValue: Bool? = nil) {
        if let autoRestoreValue {
            autoRestoreOnQuit = autoRestoreValue
        }
        isPrivateAPIAvailable = displayManager.isPrivateAPIAvailable
        displays = displayManager.listDisplays(includeBuiltin: true)
        presets = displayManager.listPresets()
        livePlacements = displayManager.captureCurrentLayout()
        savedRuleUUIDs = Set(displayManager.listDisableRules().map(\.targetDisplayUUID))
        launchAtLoginEnabled = launchAtLogin.isEnabled

        for display in displays {
            if renameDrafts[display.uuid] == nil {
                renameDrafts[display.uuid] = display.customName ?? display.name
            }
        }

        if selectedLiveUUID == nil || !livePlacements.contains(where: { $0.uuid == selectedLiveUUID }) {
            selectedLiveUUID = livePlacements.first?.uuid
        }
        if selectedRuleTargetUUID == nil || !displays.contains(where: { $0.uuid == selectedRuleTargetUUID }) {
            selectedRuleTargetUUID = displays.first(where: { !$0.isBuiltin })?.uuid ?? displays.first?.uuid
            loadRuleForSelectedTarget()
        }

        audioDevices = audioManager.listOutputDevices()
        let snapshot = audioManager.currentVolumeSnapshot(readHardwareDDC: readHardwareDDC)
        volume = snapshot.volume
        isMuted = snapshot.isMuted
        volumeMode = snapshot.mode
        volumeTargetName = snapshot.deviceName

        ddcEndpoints = audioManager.listDDCEndpoints()
        displayToDDCIndex = audioManager.matchAllDDCEndpoints(for: displays, endpoints: ddcEndpoints)

        for ep in ddcEndpoints {
            if let vol = ep.currentVolume {
                ddcVolumes[ep.index] = Double(vol) / 100.0
            } else if ddcVolumes[ep.index] == nil {
                ddcVolumes[ep.index] = 0.5
            }
            ddcMuted[ep.index] = ep.isMuted
            if let cachedStatus = audioManager.cachedDisplayInputStatus(endpointIndex: ep.index) {
                inputStatuses[ep.index] = cachedStatus
            }
        }

        if readHardwareDDC {
            refreshAllInputStatusesAsync()
        }
    }

    func refreshAllInputStatusesAsync() {
        let indices = ddcEndpoints.map(\.index)
        guard !indices.isEmpty else { return }
        let audioMgr = audioManager

        Task.detached(priority: .userInitiated) {
            var results: [Int: DisplayInputStatus] = [:]
            for idx in indices {
                results[idx] = audioMgr.readDisplayInputStatus(endpointIndex: idx)
            }
            let finalResults = results
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (idx, status) in finalResults {
                    self.inputStatuses[idx] = status
                }
            }
        }
    }

    func refreshSingleInputStatusAsync(endpointIndex: Int) {
        let audioMgr = audioManager
        Task.detached(priority: .userInitiated) {
            let status = audioMgr.readDisplayInputStatus(endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                self?.inputStatuses[endpointIndex] = status
            }
        }
    }

    // MARK: - Computed Properties

    var hasActiveExternal: Bool {
        displays.contains { !$0.isBuiltin && $0.isEnabledForDisplay }
    }

    var hasAnyDisabledDisplay: Bool {
        displays.contains { $0.usageMode == .disabled || $0.disabledByApp }
    }

    var hasAnyMirroredDisplay: Bool {
        displays.contains { $0.usageMode.isMirrored }
    }

    var activeDDCEndpointIndex: Int? {
        if case .ddc(let idx, _) = volumeMode {
            return idx
        }
        return nil
    }

    func hasDisableRule(for uuid: String) -> Bool {
        displayManager.disableRule(forDisplayUUID: uuid) != nil
    }

    /// 返回某台显示器可以镜像的目标源屏幕列表（所有除自己外的其他已启用独立屏）
    func availableMirrorMasters(for display: DisplayInfo) -> [DisplayInfo] {
        displays.filter { $0.id != display.id && $0.isIndependentActive }
    }

    // MARK: - Display Power & Role Actions (Main / Extended / Mirrored)

    func setDisplay(_ display: DisplayInfo, enabled: Bool) {
        clearBanner()
        do {
            try displayManager.setDisplay(id: display.id, enabled: enabled)
            showBanner(enabled ? "已开启「\(display.name)」" : "已停用「\(display.name)」", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
            refresh(readHardwareDDC: false)
        }
    }

    func setDisplayAsMain(_ display: DisplayInfo) {
        clearBanner()
        do {
            try displayManager.setAsMainDisplay(id: display.id)
            showBanner("已将「\(display.name)」设为主屏幕", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
            refresh(readHardwareDDC: false)
        }
    }

    func setDisplayAsExtended(_ display: DisplayInfo) {
        clearBanner()
        do {
            try displayManager.setAsExtendedDisplay(id: display.id)
            showBanner("已将「\(display.name)」设为拓展显示器", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
            refresh(readHardwareDDC: false)
        }
    }

    func setDisplayAsMirror(_ display: DisplayInfo, master: DisplayInfo) {
        clearBanner()
        do {
            try displayManager.setMirrorDisplay(id: display.id, masterID: master.id)
            showBanner("「\(display.name)」现已镜像「\(master.name)」", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
            refresh(readHardwareDDC: false)
        }
    }

    func stopAllMirroring() {
        clearBanner()
        do {
            let ids = try displayManager.stopAllMirroring()
            if !ids.isEmpty {
                showBanner("已取消全部屏幕镜像", isError: false)
            }
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func disableAllExternal() {
        clearBanner()
        do {
            try displayManager.disableAllExternal()
            showBanner("已停用全部外接显示器", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func enableAllDisplays() {
        clearBanner()
        do {
            try displayManager.enableAllDisplays()
            showBanner("已恢复全部显示器", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func identifyDisplays(onlyUUID: String? = nil) {
        DisplayIdentifierOverlay.shared.identify(displays: displays, onlyUUID: onlyUUID)
    }

    // MARK: - Custom Display Naming

    func saveCustomName(for uuid: String) {
        let draft = renameDrafts[uuid] ?? ""
        displayManager.setCustomName(draft, forDisplayUUID: uuid)
        refresh(readHardwareDDC: false)
        if let updated = displays.first(where: { $0.uuid == uuid }) {
            renameDrafts[uuid] = updated.customName ?? updated.name
        }
        showBanner("已更新显示器名称", isError: false)
        onStatusChanged()
    }

    func resetCustomName(for uuid: String) {
        displayManager.setCustomName(nil, forDisplayUUID: uuid)
        refresh(readHardwareDDC: false)
        if let updated = displays.first(where: { $0.uuid == uuid }) {
            renameDrafts[uuid] = updated.name
        }
        showBanner("已恢复系统默认名称", isError: false)
        onStatusChanged()
    }

    // MARK: - Layout Arrangement & Presets

    func applyLiveLayout() {
        clearBanner()
        do {
            try displayManager.applyLayout(livePlacements)
            showBanner("已应用当前多屏布局", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func saveCurrentAsPreset() {
        let preset = displayManager.savePreset(name: newPresetName, placements: livePlacements)
        newPresetName = ""
        presets = displayManager.listPresets()
        showBanner("已保存布局预设「\(preset.name)」", isError: false)
        onStatusChanged()
    }

    func applyPreset(_ preset: LayoutPreset) {
        clearBanner()
        do {
            try displayManager.applyPreset(id: preset.id)
            showBanner("已切换到布局预设「\(preset.name)」", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func deletePreset(_ preset: LayoutPreset) {
        displayManager.deletePreset(id: preset.id)
        presets = displayManager.listPresets()
        showBanner("已删除预设「\(preset.name)」", isError: false)
        onStatusChanged()
    }

    func markPlacementAsMain(uuid: String, inLive: Bool) {
        if inLive {
            livePlacements = Self.settingMain(uuid: uuid, in: livePlacements)
        } else {
            rulePlacements = Self.settingMain(uuid: uuid, in: rulePlacements)
        }
    }

    func placeSelected(_ side: RelativeSide, inLive: Bool) {
        let selectedUUID = inLive ? selectedLiveUUID : selectedRuleItemUUID
        guard let selectedUUID else { return }
        var list = inLive ? livePlacements : rulePlacements
        guard let targetIdx = list.firstIndex(where: { $0.uuid == selectedUUID }) else { return }
        guard let anchor = list.first(where: { $0.isMain && $0.uuid != selectedUUID })
                ?? list.first(where: { $0.uuid != selectedUUID }) else {
            return
        }

        let target = list[targetIdx]
        switch side {
        case .left:
            list[targetIdx].x = anchor.x - target.width
            list[targetIdx].y = anchor.y + (anchor.height - target.height) / 2
        case .right:
            list[targetIdx].x = anchor.x + anchor.width
            list[targetIdx].y = anchor.y + (anchor.height - target.height) / 2
        case .top:
            list[targetIdx].x = anchor.x + (anchor.width - target.width) / 2
            list[targetIdx].y = anchor.y - target.height
        case .bottom:
            list[targetIdx].x = anchor.x + (anchor.width - target.width) / 2
            list[targetIdx].y = anchor.y + anchor.height
        }

        let updated = Self.normalized(list)
        if inLive {
            livePlacements = updated
        } else {
            rulePlacements = updated
        }
    }

    static func settingMain(uuid: String, in placements: [DisplayPlacement]) -> [DisplayPlacement] {
        var copy = placements
        for idx in copy.indices {
            copy[idx].isMain = (copy[idx].uuid == uuid)
        }
        return normalized(copy)
    }

    static func normalized(_ placements: [DisplayPlacement]) -> [DisplayPlacement] {
        guard !placements.isEmpty else { return [] }
        var copy = placements
        if !copy.contains(where: \.isMain) {
            copy[0].isMain = true
        }
        let main = copy.first(where: \.isMain) ?? copy[0]
        let dx = main.x
        let dy = main.y
        for idx in copy.indices {
            copy[idx].x -= dx
            copy[idx].y -= dy
        }
        return copy
    }

    // MARK: - Disable Rules Editor

    func selectRuleTarget(uuid: String) {
        selectedRuleTargetUUID = uuid
        loadRuleForSelectedTarget()
    }

    func loadRuleForSelectedTarget() {
        guard let targetUUID = selectedRuleTargetUUID else {
            rulePlacements = []
            selectedRuleItemUUID = nil
            return
        }

        if let existing = displayManager.disableRule(forDisplayUUID: targetUUID) {
            rulePlacements = existing.layoutOnDisable
            restorePreviousOnEnable = existing.restorePreviousOnEnable
        } else {
            let remaining = displays.filter { $0.uuid != targetUUID }
            var placements = remaining.map {
                DisplayPlacement(
                    uuid: $0.uuid,
                    name: $0.name,
                    x: $0.originX,
                    y: $0.originY,
                    width: max($0.width, 1),
                    height: max($0.height, 1),
                    isMain: $0.isMain
                )
            }
            if !placements.isEmpty && !placements.contains(where: \.isMain) {
                placements[0].isMain = true
            }
            rulePlacements = Self.normalized(placements)
            restorePreviousOnEnable = true
        }

        if selectedRuleItemUUID == nil || !rulePlacements.contains(where: { $0.uuid == selectedRuleItemUUID }) {
            selectedRuleItemUUID = rulePlacements.first?.uuid
        }
    }

    func captureCurrentIntoRule() {
        guard let targetUUID = selectedRuleTargetUUID else { return }
        let current = displayManager.captureCurrentLayout().filter { $0.uuid != targetUUID }
        guard !current.isEmpty else {
            showBanner("当前没有可捕获的剩余活跃屏幕", isError: true)
            return
        }
        rulePlacements = Self.normalized(current)
        selectedRuleItemUUID = rulePlacements.first?.uuid
        showBanner("已捕获当前剩余屏幕布局，请点击「保存规则」生效", isError: false)
    }

    func saveRuleForSelectedTarget() {
        guard let targetUUID = selectedRuleTargetUUID,
              let target = displays.first(where: { $0.uuid == targetUUID }) else {
            return
        }
        let normalized = Self.normalized(rulePlacements)
        let rule = DisableLayoutRule(
            targetDisplayUUID: targetUUID,
            targetDisplayName: target.name,
            layoutOnDisable: normalized,
            restorePreviousOnEnable: restorePreviousOnEnable
        )
        displayManager.saveDisableRule(rule)
        rulePlacements = normalized
        savedRuleUUIDs = Set(displayManager.listDisableRules().map(\.targetDisplayUUID))
        showBanner("已保存关闭「\(target.name)」后的布局规则", isError: false)
        onStatusChanged()
    }

    func deleteRuleForSelectedTarget() {
        guard let targetUUID = selectedRuleTargetUUID,
              let target = displays.first(where: { $0.uuid == targetUUID }) else {
            return
        }
        displayManager.deleteDisableRule(forDisplayUUID: targetUUID)
        savedRuleUUIDs = Set(displayManager.listDisableRules().map(\.targetDisplayUUID))
        loadRuleForSelectedTarget()
        showBanner("已清除「\(target.name)」的关闭规则", isError: false)
        onStatusChanged()
    }

    // MARK: - Input Source Actions

    func setInputProtocolMode(_ mode: InputSourceProtocolMode) {
        inputProtocolMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.inputProtocolKey)
        showBanner("输入源协议已切换为：\(mode.label)", isError: false)
    }

    func switchInputSource(_ source: DisplayInputSource, endpointIndex: Int, displayName: String) {
        switchingInputs[endpointIndex] = source
        showBanner("正在将「\(displayName)」切换至 \(source.label)…", isError: false, autoClear: false)

        let audioMgr = audioManager
        let mode = inputProtocolMode

        Task.detached(priority: .userInitiated) {
            let ok = audioMgr.setDisplayInputSource(source, endpointIndex: endpointIndex, protocolMode: mode)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.switchingInputs.removeValue(forKey: endpointIndex)
                if ok {
                    let existing = self.inputStatuses[endpointIndex]
                    self.inputStatuses[endpointIndex] = DisplayInputStatus(
                        activeSource: source,
                        rawRead: existing?.rawRead ?? DDCInputReadResult(),
                        calibratedCodes: existing?.calibratedCodes ?? [:]
                    )
                    self.showBanner("已发送信号源切换：\(displayName) → \(source.label)", isError: false)
                } else {
                    self.showBanner("「\(displayName)」切换至 \(source.label) 失败，可点击 ⚙︎ 校准该端口。", isError: true)
                }
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let updatedStatus = audioMgr.readDisplayInputStatus(endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if updatedStatus.activeSource != nil || !updatedStatus.rawRead.isEmpty {
                    self.inputStatuses[endpointIndex] = updatedStatus
                }
            }
        }
    }

    func calibrateCurrentInput(as source: DisplayInputSource, endpointIndex: Int, displayName: String) {
        showBanner("正在读取「\(displayName)」当前端口硬件码…", isError: false, autoClear: false)
        let audioMgr = audioManager

        Task.detached(priority: .userInitiated) {
            let code = audioMgr.calibrateCurrentInputSource(as: source, endpointIndex: endpointIndex)
            let refreshed = audioMgr.cachedDisplayInputStatus(endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let refreshed {
                    self.inputStatuses[endpointIndex] = refreshed
                }
                if let code {
                    self.showBanner("校准成功：「\(displayName)」的 \(source.label) 已绑定为 \(code.hexSummary)", isError: false)
                } else {
                    self.showBanner("未能从「\(displayName)」读出当前端口码，请确认线缆支持 DDC/CI。", isError: true)
                }
            }
        }
    }

    func resetInputCalibration(endpointIndex: Int, displayName: String) {
        audioManager.resetInputCalibration(endpointIndex: endpointIndex)
        refreshSingleInputStatusAsync(endpointIndex: endpointIndex)
        showBanner("已重置「\(displayName)」的输入源校准", isError: false)
    }

    // MARK: - Audio Actions

    func selectAudioOutput(_ device: AudioOutputDevice) {
        clearBanner()
        if audioManager.selectOutputDevice(id: device.id) {
            refresh(readHardwareDDC: true)
        } else {
            showBanner("切换音频输出设备「\(device.name)」失败。", isError: true)
        }
    }

    func updateMainVolume(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 1.0)
        volume = clamped
        if clamped > 0.001 && isMuted {
            isMuted = false
        }

        switch volumeMode {
        case .coreAudio:
            _ = audioManager.setCurrentVolume(clamped)
        case .ddc(let idx, _):
            ddcVolumes[idx] = clamped
            if clamped > 0.001 {
                ddcMuted[idx] = false
            }
            pendingVolumeWorkItem?.cancel()
            let audioMgr = audioManager
            let work = DispatchWorkItem {
                Task.detached(priority: .userInitiated) {
                    _ = audioMgr.setCurrentVolume(clamped)
                }
            }
            pendingVolumeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        case .unsupported:
            break
        }
    }

    func toggleMainMute() {
        let nextMuted = !isMuted
        isMuted = nextMuted
        let audioMgr = audioManager

        if case .coreAudio = volumeMode {
            _ = audioMgr.setCurrentMuted(nextMuted)
            let snap = audioMgr.currentVolumeSnapshot(readHardwareDDC: false)
            volume = snap.volume
            isMuted = snap.isMuted
        } else {
            Task.detached(priority: .userInitiated) {
                _ = audioMgr.setCurrentMuted(nextMuted)
                let snap = audioMgr.currentVolumeSnapshot(readHardwareDDC: false)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.volume = snap.volume
                    self.isMuted = snap.isMuted
                    if case .ddc(let idx, _) = snap.mode {
                        self.ddcVolumes[idx] = snap.volume
                        self.ddcMuted[idx] = snap.isMuted
                    }
                }
            }
        }
    }

    func updateDDCVolume(endpointIndex: Int, value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        ddcVolumes[endpointIndex] = clamped
        if clamped > 0.001 {
            ddcMuted[endpointIndex] = false
        }
        if case .ddc(let currentIdx, _) = volumeMode, currentIdx == endpointIndex {
            volume = clamped
            if clamped > 0.001 {
                isMuted = false
            }
        }

        pendingDDCWorkItems[endpointIndex]?.cancel()
        let audioMgr = audioManager
        let work = DispatchWorkItem {
            let percent = Int((clamped * 100.0).rounded())
            Task.detached(priority: .userInitiated) {
                _ = audioMgr.setDDCVolume(percent, endpointIndex: endpointIndex)
            }
        }
        pendingDDCWorkItems[endpointIndex] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func toggleDDCMute(endpointIndex: Int) {
        let nextMuted = !(ddcMuted[endpointIndex] ?? false)
        ddcMuted[endpointIndex] = nextMuted
        let audioMgr = audioManager
        Task.detached(priority: .userInitiated) {
            _ = audioMgr.setDDCMuted(nextMuted, endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                self?.refresh(readHardwareDDC: false)
            }
        }
    }

    func bindActiveAudioToDDC(endpointIndex: Int) {
        guard let active = audioDevices.first(where: \.isDefault) else { return }
        audioManager.bindDDCEndpoint(endpointIndex, forAudioDeviceUID: active.uid)
        refresh(readHardwareDDC: true)
    }

    func bindDisplay(_ displayUUID: String, toDDCEndpoint endpoint: DDCDisplayEndpoint) {
        audioManager.bindDisplay(displayUUID, toEndpoint: endpoint)
        refresh(readHardwareDDC: true)
        if let name = displays.first(where: { $0.uuid == displayUUID })?.name {
            showBanner("已将「\(name)」绑定至硬件通道 #\(endpoint.index + 1)", isError: false)
        }
    }

    // MARK: - Formatting Helpers

    func displayTitle(for device: AudioOutputDevice) -> String {
        if let epIdx = audioManager.matchedDDCEndpointIndex(for: device, allDevices: audioDevices),
           let matchedUUID = displayToDDCIndex.first(where: { $0.value == epIdx })?.key,
           let matchedDisplay = displays.first(where: { $0.uuid == matchedUUID }),
           let custom = matchedDisplay.customName, !custom.isEmpty {
            return "\(custom)（\(device.name)）"
        }
        let sameName = audioDevices.filter { $0.name == device.name }
        guard sameName.count > 1,
              let idx = sameName.firstIndex(where: { $0.id == device.id }) else {
            return device.name
        }
        return "\(device.name) #\(idx + 1)"
    }

    func displayTitle(for endpoint: DDCDisplayEndpoint) -> String {
        if let matchedUUID = displayToDDCIndex.first(where: { $0.value == endpoint.index })?.key,
           let matchedDisplay = displays.first(where: { $0.uuid == matchedUUID }) {
            return matchedDisplay.name
        }
        let sameName = ddcEndpoints.filter { $0.name == endpoint.name }
        guard sameName.count > 1,
              let idx = sameName.firstIndex(where: { $0.index == endpoint.index }) else {
            return endpoint.name
        }
        return "\(endpoint.name) #\(idx + 1)"
    }

    func mainTargetDisplayTitle() -> String {
        if let activeIdx = activeDDCEndpointIndex,
           let ep = ddcEndpoints.first(where: { $0.index == activeIdx }) {
            return displayTitle(for: ep)
        }
        if let activeDevice = audioDevices.first(where: \.isDefault) {
            return displayTitle(for: activeDevice)
        }
        return volumeTargetName ?? "无可用输出设备"
    }

    // MARK: - App Window & Preferences

    func toggleLaunchAtLogin() {
        clearBanner()
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            launchAtLoginEnabled = launchAtLogin.isEnabled
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func toggleAutoRestore() {
        onToggleAutoRestore()
    }

    func openMainWindow(section: MainWindowSection? = nil) {
        if let section {
            mainSection = section
        }
        onOpenMainWindow(section)
    }

    func promptSavePreset() {
        onPromptSavePreset()
    }

    func quitApp() {
        onQuit()
    }

    // MARK: - Banner

    func showBanner(_ text: String, isError: Bool, autoClear: Bool = true) {
        bannerClearWorkItem?.cancel()
        statusBanner = (text, isError)
        guard autoClear else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.statusBanner = nil
        }
        bannerClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 5.0 : 3.2), execute: work)
    }

    func clearBanner() {
        bannerClearWorkItem?.cancel()
        statusBanner = nil
    }
}
