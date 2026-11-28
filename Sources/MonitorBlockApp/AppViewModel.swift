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
    @Published var ddcCapabilities: [Int: DDCCapabilities] = [:]
    @Published var ddcBrightness: [Int: Double] = [:]
    @Published var inputStatuses: [Int: DisplayInputStatus] = [:]
    @Published var switchingInputs: [Int: DisplayInputSource] = [:]
    @Published var inputProtocolMode: InputSourceProtocolMode = .auto
    @Published var displayInputProtocols: [String: InputSourceProtocolMode] = [:]

    // Audio State
    @Published var audioDevices: [AudioOutputDevice] = []
    @Published var audioToDDCIndex: [UInt32: Int] = [:]
    @Published var volume: Double = 0.5
    @Published var isMuted: Bool = false
    @Published var volumeMode: VolumeControlMode = .unsupported
    @Published var volumeTargetName: String?
    @Published var ddcVolumes: [Int: Double] = [:]
    @Published var ddcMuted: [Int: Bool] = [:]
    @Published var isSoftwareVolumeEnabled: Bool = true
    @Published var softwareVolumeError: String?

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
    private static let softwareVolumeKey = "MonitorBlock.softwareVolumeEnabled"

    private var pendingVolumeWorkItem: DispatchWorkItem?
    private var pendingDDCWorkItems: [Int: DispatchWorkItem] = [:]
    private var pendingBrightnessWorkItems: [Int: DispatchWorkItem] = [:]
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

        // 全局协议始终保持 .auto（按每台显示器的 EDID 厂商与 MCCS 0xF3 硬件能力自动分流，避免实验室 DELL 与家里 LG 互相污染）；
        // 清理旧版本可能残留的全局协议覆盖，个别显示器若需固定协议均按 UUID 独立存储在 displayInputProtocols 中。
        self.inputProtocolMode = .auto
        UserDefaults.standard.removeObject(forKey: Self.inputProtocolKey)
        let softVolEnabled: Bool
        if UserDefaults.standard.object(forKey: Self.softwareVolumeKey) == nil {
            softVolEnabled = true
        } else {
            softVolEnabled = UserDefaults.standard.bool(forKey: Self.softwareVolumeKey)
        }
        self.isSoftwareVolumeEnabled = softVolEnabled
        self.audioManager.isSoftwareVolumeEnabled = softVolEnabled

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

        audioManager.updateKnownDisplays(displays)

        let rawEndpoints = audioManager.listDDCEndpoints()
        let displayMapping = audioManager.matchAllDDCEndpoints(for: displays, endpoints: rawEndpoints)
        displayToDDCIndex = displayMapping

        // 按显示器物理从左到右的顺序排列 DDC 音量卡片（与「显示器」「布局」页视觉顺序完全一致）
        let displayOrderByDDCIndex: [Int: Int] = {
            var order: [Int: Int] = [:]
            for (pos, display) in displays.enumerated() {
                if let epIdx = displayMapping[display.uuid] {
                    order[epIdx] = pos
                }
            }
            return order
        }()
        ddcEndpoints = rawEndpoints.sorted { lhs, rhs in
            let lPos = displayOrderByDDCIndex[lhs.index] ?? (1000 + lhs.index)
            let rPos = displayOrderByDDCIndex[rhs.index] ?? (1000 + rhs.index)
            if lPos != rPos { return lPos < rPos }
            return lhs.index < rhs.index
        }

        audioDevices = audioManager.listOutputDevices()
        audioToDDCIndex = audioManager.matchAllAudioToDDCEndpoints(
            audioDevices: audioDevices,
            displays: displays,
            endpoints: rawEndpoints
        )
        let snapshot = audioManager.currentVolumeSnapshot(readHardwareDDC: false, activateSoftwareVolumeIfNeeded: false)
        volume = snapshot.volume
        isMuted = snapshot.isMuted
        volumeMode = snapshot.mode
        volumeTargetName = snapshot.deviceName
        softwareVolumeError = audioManager.softwareVolumeLastError

        var perDisplayProtocols: [String: InputSourceProtocolMode] = [:]
        for display in displays where !display.isBuiltin {
            if let overrideMode = audioManager.displayInputProtocol(forDisplayUUID: display.uuid) {
                perDisplayProtocols[display.uuid] = overrideMode
            }
        }
        displayInputProtocols = perDisplayProtocols

        var nextCapabilities: [Int: DDCCapabilities] = [:]
        var nextBrightness: [Int: Double] = [:]
        var nextVolumes: [Int: Double] = [:]
        var nextMuted: [Int: Bool] = [:]
        var nextInputStatuses: [Int: DisplayInputStatus] = [:]

        for ep in ddcEndpoints {
            let matchedUUID = displayMapping.first(where: { $0.value == ep.index })?.key
            if let caps = ep.capabilities {
                nextCapabilities[ep.index] = caps
            }
            if let bright = ep.currentBrightness {
                nextBrightness[ep.index] = Double(bright) / 100.0
            } else {
                nextBrightness[ep.index] = ddcBrightness[ep.index] ?? 0.5
            }
            if let vol = ep.currentVolume {
                nextVolumes[ep.index] = Double(vol) / 100.0
            } else {
                nextVolumes[ep.index] = ddcVolumes[ep.index] ?? 0.5
            }
            nextMuted[ep.index] = ep.isMuted
            if let cachedStatus = audioManager.cachedDisplayInputStatus(endpointIndex: ep.index, displayUUID: matchedUUID) {
                nextInputStatuses[ep.index] = cachedStatus
            }
        }

        ddcCapabilities = nextCapabilities
        ddcBrightness = nextBrightness
        ddcVolumes = nextVolumes
        ddcMuted = nextMuted
        inputStatuses = nextInputStatuses

        if readHardwareDDC {
            probeDDCStateAsync()
        }
    }

    func probeDDCStateAsync(forceCapabilities: Bool = false) {
        let targets: [(index: Int, uuid: String?)] = ddcEndpoints.map { ep in
            let uuid = displayToDDCIndex.first(where: { $0.value == ep.index })?.key
            return (ep.index, uuid)
        }
        guard !targets.isEmpty else { return }
        let audioMgr = audioManager

        Task.detached(priority: .userInitiated) {
            var capsMap: [Int: DDCCapabilities] = [:]
            var inputMap: [Int: DisplayInputStatus] = [:]
            for item in targets {
                let caps = audioMgr.probeCapabilitiesAndBrightness(
                    endpointIndex: item.index,
                    displayUUID: item.uuid,
                    force: forceCapabilities
                )
                capsMap[item.index] = caps
                if caps.isReachable {
                    inputMap[item.index] = audioMgr.readDisplayInputStatus(
                        endpointIndex: item.index,
                        displayUUID: item.uuid
                    )
                }
            }
            let updatedEndpoints = audioMgr.listDDCEndpoints()
            let updatedSnapshot = audioMgr.currentVolumeSnapshot(readHardwareDDC: false, activateSoftwareVolumeIfNeeded: false)
            let lastErr = audioMgr.softwareVolumeLastError

            let finalCaps = capsMap
            let finalInputs = inputMap
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (idx, caps) in finalCaps {
                    self.ddcCapabilities[idx] = caps
                }
                for ep in updatedEndpoints {
                    if let bright = ep.currentBrightness {
                        self.ddcBrightness[ep.index] = Double(bright) / 100.0
                    }
                    if let vol = ep.currentVolume {
                        self.ddcVolumes[ep.index] = Double(vol) / 100.0
                    }
                }
                for (idx, status) in finalInputs {
                    if status.activeSource == nil, let prevActive = self.inputStatuses[idx]?.activeSource {
                        self.inputStatuses[idx] = DisplayInputStatus(
                            activeSource: prevActive,
                            rawRead: status.rawRead,
                            calibratedCodes: status.calibratedCodes
                        )
                    } else {
                        self.inputStatuses[idx] = status
                    }
                }
                self.volume = updatedSnapshot.volume
                self.isMuted = updatedSnapshot.isMuted
                self.volumeMode = updatedSnapshot.mode
                self.volumeTargetName = updatedSnapshot.deviceName
                self.softwareVolumeError = lastErr
            }
        }
    }

    func refreshAllInputStatusesAsync() {
        probeDDCStateAsync(forceCapabilities: false)
    }

    func refreshSingleInputStatusAsync(endpointIndex: Int, displayUUID: String? = nil) {
        let audioMgr = audioManager
        Task.detached(priority: .userInitiated) {
            let status = audioMgr.readDisplayInputStatus(endpointIndex: endpointIndex, displayUUID: displayUUID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let targetIdx = displayUUID.flatMap { self.displayToDDCIndex[$0] } ?? endpointIndex
                if status.activeSource == nil, let prevActive = self.inputStatuses[targetIdx]?.activeSource {
                    self.inputStatuses[targetIdx] = DisplayInputStatus(
                        activeSource: prevActive,
                        rawRead: status.rawRead,
                        calibratedCodes: status.calibratedCodes
                    )
                } else {
                    self.inputStatuses[targetIdx] = status
                }
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

    var isSoftwareVolumeSupported: Bool {
        audioManager.isSoftwareVolumeSupported
    }

    /// 仅返回支持 DDC/CI 硬件音量（或尚未完成能力探测）的外接显示器，隐藏 EIZO / Dell U2718Q 等无效滑块
    var ddcVolumeEndpoints: [DDCDisplayEndpoint] {
        ddcEndpoints.filter { ep in
            guard let caps = ddcCapabilities[ep.index] ?? ep.capabilities else {
                return true
            }
            return caps.isReachable && caps.supportsVolume
        }
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
        showBanner("全局默认输入源协议已切换为：\(mode.label)", isError: false)
    }

    func setDisplayInputProtocol(_ mode: InputSourceProtocolMode?, for displayUUID: String, displayName: String) {
        audioManager.setDisplayInputProtocol(mode, forDisplayUUID: displayUUID)
        if let mode {
            displayInputProtocols[displayUUID] = mode
            showBanner("已将「\(displayName)」的输入源协议设为：\(mode.label)", isError: false)
        } else {
            displayInputProtocols.removeValue(forKey: displayUUID)
            showBanner("「\(displayName)」已恢复跟随全局默认协议（\(inputProtocolMode.label)）", isError: false)
        }
    }

    func switchInputSource(
        _ source: DisplayInputSource,
        displayUUID: String,
        endpointIndex: Int,
        displayName: String
    ) {
        // 先同步最新在线屏幕拓扑，防止其他屏幕刚切走后 dispextN 索引发生偏移
        let latestDisplays = displayManager.listDisplays(includeBuiltin: true)
        audioManager.updateKnownDisplays(latestDisplays)
        let liveMapping = audioManager.matchAllDDCEndpoints(for: latestDisplays)
        let resolvedIndex = liveMapping[displayUUID] ?? endpointIndex
        displayToDDCIndex = liveMapping

        switchingInputs[resolvedIndex] = source
        showBanner("正在将「\(displayName)」切换至 \(source.label)…", isError: false, autoClear: false)

        let audioMgr = audioManager
        let mode = inputProtocolMode

        Task.detached(priority: .userInitiated) {
            let ok = audioMgr.setDisplayInputSource(
                source,
                endpointIndex: resolvedIndex,
                protocolMode: mode,
                displayUUID: displayUUID
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.switchingInputs.removeValue(forKey: resolvedIndex)
                if ok {
                    let existing = self.inputStatuses[resolvedIndex]
                    self.inputStatuses[resolvedIndex] = DisplayInputStatus(
                        activeSource: source,
                        rawRead: existing?.rawRead ?? DDCInputReadResult(),
                        calibratedCodes: existing?.calibratedCodes ?? [:]
                    )
                    self.showBanner("已发送信号源切换：\(displayName) → \(source.label)", isError: false)
                } else {
                    self.showBanner("「\(displayName)」切换至 \(source.label) 失败，可点击 ⚙︎ 调整协议或端口编码。", isError: true)
                }
            }

            guard ok else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let updatedStatus = audioMgr.readDisplayInputStatus(endpointIndex: resolvedIndex, displayUUID: displayUUID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let currentIdx = self.displayToDDCIndex[displayUUID] ?? resolvedIndex
                if updatedStatus.activeSource != nil {
                    self.inputStatuses[currentIdx] = updatedStatus
                } else {
                    // 对 0xF4 只写不回读或 0x60 返回 0x00 的 LG 显示器，保留刚刚选中的端口高亮，仅更新底层 rawRead
                    self.inputStatuses[currentIdx] = DisplayInputStatus(
                        activeSource: source,
                        rawRead: updatedStatus.rawRead,
                        calibratedCodes: updatedStatus.calibratedCodes
                    )
                }
            }
        }
    }

    func calibrateCurrentInput(
        as source: DisplayInputSource,
        displayUUID: String,
        endpointIndex: Int,
        displayName: String
    ) {
        showBanner("正在读取「\(displayName)」当前端口硬件码…", isError: false, autoClear: false)
        let audioMgr = audioManager

        Task.detached(priority: .userInitiated) {
            let code = audioMgr.calibrateCurrentInputSource(
                as: source,
                endpointIndex: endpointIndex,
                displayUUID: displayUUID
            )
            let refreshed = audioMgr.cachedDisplayInputStatus(endpointIndex: endpointIndex, displayUUID: displayUUID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let targetIdx = self.displayToDDCIndex[displayUUID] ?? endpointIndex
                if let refreshed {
                    self.inputStatuses[targetIdx] = refreshed
                }
                if let code {
                    self.showBanner("校准成功：「\(displayName)」的 \(source.label) 已绑定为 \(code.hexSummary)", isError: false)
                } else {
                    self.showBanner("此屏未公开当前端口回读码（如 LG 0xF4 只写固件），可在 ⚙︎ →「手动指定端口硬件码」中直接选择。", isError: true)
                }
            }
        }
    }

    func setManualInputCode(
        _ code: DDCInputCode?,
        for source: DisplayInputSource,
        displayUUID: String,
        endpointIndex: Int,
        displayName: String
    ) {
        audioManager.setManualInputCode(code, for: source, endpointIndex: endpointIndex, displayUUID: displayUUID)
        let targetIdx = displayToDDCIndex[displayUUID] ?? endpointIndex
        if let refreshed = audioManager.cachedDisplayInputStatus(endpointIndex: targetIdx, displayUUID: displayUUID) {
            inputStatuses[targetIdx] = refreshed
        }
        if let code {
            showBanner("已将「\(displayName)」的 \(source.label) 手动绑定为 \(code.hexSummary)", isError: false)
        } else {
            showBanner("已恢复「\(displayName)」的 \(source.label) 默认编码", isError: false)
        }
    }

    func resetInputCalibration(displayUUID: String, endpointIndex: Int, displayName: String) {
        audioManager.resetInputCalibration(endpointIndex: endpointIndex, displayUUID: displayUUID)
        refreshSingleInputStatusAsync(endpointIndex: endpointIndex, displayUUID: displayUUID)
        showBanner("已重置「\(displayName)」的输入源校准", isError: false)
    }

    func resetAllDDCCustomizations() {
        audioManager.resetAllDDCCustomizations()
        inputProtocolMode = .auto
        UserDefaults.standard.removeObject(forKey: Self.inputProtocolKey)
        displayInputProtocols.removeAll()
        refresh(readHardwareDDC: true)
        showBanner("已清除所有历史手动 DDC 绑定与校准，恢复纯自动硬件识别", isError: false)
    }

    func updateDDCBrightness(endpointIndex: Int, displayUUID: String? = nil, value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        ddcBrightness[endpointIndex] = clamped

        pendingBrightnessWorkItems[endpointIndex]?.cancel()
        let audioMgr = audioManager
        let work = DispatchWorkItem {
            let percent = Int((clamped * 100.0).rounded())
            Task.detached(priority: .userInitiated) {
                _ = audioMgr.setDDCBrightness(percent, endpointIndex: endpointIndex, displayUUID: displayUUID)
            }
        }
        pendingBrightnessWorkItems[endpointIndex] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    // MARK: - Audio Actions

    func selectAudioOutput(_ device: AudioOutputDevice) {
        clearBanner()
        softwareVolumeError = nil
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
        case .software:
            if audioManager.isSoftwareVolumeActive {
                // 已激活时直接原子更新实时增益，零延迟无卡顿
                _ = audioManager.setCurrentVolume(clamped)
                softwareVolumeError = nil
            } else {
                // 首次拖动合并为单次后台激活，避免并发多次创建 Process Tap
                pendingVolumeWorkItem?.cancel()
                let audioMgr = audioManager
                let work = DispatchWorkItem {
                    Task.detached(priority: .userInitiated) {
                        let ok = audioMgr.setCurrentVolume(clamped)
                        let err = audioMgr.softwareVolumeLastError
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.softwareVolumeError = ok ? nil : err
                            if !ok, let err {
                                self.showBanner(err, isError: true)
                            }
                        }
                    }
                }
                pendingVolumeWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            }
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
                let ok = audioMgr.setCurrentMuted(nextMuted)
                let err = audioMgr.softwareVolumeLastError
                let snap = audioMgr.currentVolumeSnapshot(readHardwareDDC: false)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.volume = snap.volume
                    self.isMuted = snap.isMuted
                    self.volumeMode = snap.mode
                    self.softwareVolumeError = ok ? nil : err
                    if !ok, let err {
                        self.showBanner(err, isError: true)
                    }
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
        if let epIdx = audioToDDCIndex[device.id],
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

    func toggleSoftwareVolumeEnabled() {
        isSoftwareVolumeEnabled.toggle()
        UserDefaults.standard.set(isSoftwareVolumeEnabled, forKey: Self.softwareVolumeKey)
        audioManager.isSoftwareVolumeEnabled = isSoftwareVolumeEnabled
        softwareVolumeError = nil
        refresh(readHardwareDDC: false)
        showBanner(
            isSoftwareVolumeEnabled ? "已启用免驱动软件音量" : "已关闭免驱动软件音量",
            isError: false
        )
    }

    func openSystemAudioRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
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
