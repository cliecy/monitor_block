import CoreGraphics
import Foundation

public final class DisplayManager {
    private let backend: DisplayBackend
    private let store: StateStoreProtocol
    private var cache: [CGDirectDisplayID: CachedDisplayRecord]
    private var presets: [LayoutPreset]
    private var disableRules: [String: DisableLayoutRule]
    private var preDisableSnapshots: [String: [DisplayPlacement]]
    private var customNames: [String: String]

    public var isPrivateAPIAvailable: Bool {
        backend.isPrivateAPIAvailable
    }

    public init(
        backend: DisplayBackend = CoreGraphicsBackend(),
        store: StateStoreProtocol = FileStateStore()
    ) {
        self.backend = backend
        self.store = store
        let loaded = store.loadState()
        self.cache = Dictionary(uniqueKeysWithValues: loaded.cachedDisplays.map { ($0.id, $0) })
        self.presets = loaded.presets
        self.disableRules = loaded.disableRules
        self.preDisableSnapshots = loaded.preDisableSnapshots
        self.customNames = loaded.customNames
    }

    private func persist() {
        let existing = store.loadState()
        let state = PersistedAppState(
            cachedDisplays: cache.values.sorted { $0.id < $1.id },
            presets: presets,
            disableRules: disableRules,
            preDisableSnapshots: preDisableSnapshots,
            customNames: customNames,
            audioToDDCBindings: existing.audioToDDCBindings,
            calibratedInputCodes: existing.calibratedInputCodes
        )
        store.saveState(state)
    }

    // MARK: - Display Listing

    public func listDisplays(includeBuiltin: Bool = false) -> [DisplayInfo] {
        let snapshots = backend.fetchDisplays()
        var liveIDs = Set<CGDirectDisplayID>()
        var cacheChanged = false

        // 第一遍：计算每块在线屏幕的显示名称与 UUID，供镜像从属屏解析 masterName
        var resolvedMetaByID: [CGDirectDisplayID: (uuid: String, name: String, systemName: String, customName: String?)] = [:]
        for snap in snapshots {
            let existing = cache[snap.id]
            let systemName: String
            if let name = snap.name, !name.isEmpty {
                systemName = name
            } else if let cachedName = existing?.name, !cachedName.isEmpty {
                systemName = cachedName
            } else if snap.isBuiltin {
                systemName = "内置显示器"
            } else {
                systemName = "外接显示器 #\(snap.id)"
            }
            let customName = customNames[snap.uuid]
            let resolvedName = customName ?? systemName
            resolvedMetaByID[snap.id] = (snap.uuid, resolvedName, systemName, customName)
        }

        var results: [DisplayInfo] = []

        for snap in snapshots {
            liveIDs.insert(snap.id)
            let existing = cache[snap.id]
            let meta = resolvedMetaByID[snap.id]!

            let resolvedWidth = snap.width > 0 ? snap.width : (existing?.width ?? 0)
            let resolvedHeight = snap.height > 0 ? snap.height : (existing?.height ?? 0)

            let isLiveEnabled = snap.isActive || snap.mirrorMasterID != nil
            var disabledByApp = existing?.disabledByApp ?? false
            if isLiveEnabled && disabledByApp {
                disabledByApp = false
                cacheChanged = true
            }

            let updated = CachedDisplayRecord(
                id: snap.id,
                uuid: snap.uuid,
                name: meta.systemName,
                width: resolvedWidth,
                height: resolvedHeight,
                disabledByApp: disabledByApp,
                isBuiltin: snap.isBuiltin
            )
            if cache[snap.id] != updated {
                cache[snap.id] = updated
                cacheChanged = true
            }

            let usageMode: DisplayUsageMode
            if disabledByApp || !isLiveEnabled {
                usageMode = .disabled
            } else if let masterID = snap.mirrorMasterID {
                let masterMeta = resolvedMetaByID[masterID]
                usageMode = .mirrored(
                    masterID: masterID,
                    masterUUID: masterMeta?.uuid ?? "",
                    masterName: masterMeta?.name ?? "显示器 #\(masterID)"
                )
            } else if snap.isMain {
                usageMode = .main
            } else {
                usageMode = .extended
            }

            if includeBuiltin || !snap.isBuiltin {
                results.append(
                    DisplayInfo(
                        id: snap.id,
                        uuid: snap.uuid,
                        serialNumber: snap.serialNumber,
                        name: meta.name,
                        systemName: meta.systemName,
                        customName: meta.customName,
                        isBuiltin: snap.isBuiltin,
                        isActive: snap.isActive,
                        isOnline: snap.isOnline,
                        originX: snap.originX,
                        originY: snap.originY,
                        width: resolvedWidth,
                        height: resolvedHeight,
                        isMain: usageMode == .main,
                        mirrorMasterID: snap.mirrorMasterID,
                        usageMode: usageMode,
                        disabledByApp: disabledByApp
                    )
                )
            }
        }

        // 将被本工具软断开后从系统在线列表中消失的显示器合并回来，方便一键恢复
        for (id, record) in cache where record.disabledByApp && !liveIDs.contains(id) {
            if !includeBuiltin && record.isBuiltin {
                continue
            }
            let customName = customNames[record.uuid]
            results.append(
                DisplayInfo(
                    id: record.id,
                    uuid: record.uuid,
                    name: customName ?? record.name,
                    systemName: record.name,
                    customName: customName,
                    isBuiltin: record.isBuiltin,
                    isActive: false,
                    isOnline: false,
                    originX: 0,
                    originY: 0,
                    width: record.width,
                    height: record.height,
                    isMain: false,
                    mirrorMasterID: nil,
                    usageMode: .disabled,
                    disabledByApp: true
                )
            )
        }

        if cacheChanged {
            persist()
        }

        return results.sorted { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin {
                return lhs.isBuiltin
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Enable / Disable with Layout Rules

    /// 启用或停用任意显示器（支持内置屏与外接屏，但严格禁止停用最后一块独立活跃屏）
    public func setDisplay(id: CGDirectDisplayID, enabled: Bool) throws {
        let allDisplays = listDisplays(includeBuiltin: true)
        guard let target = allDisplays.first(where: { $0.id == id }) else {
            throw MonitorBlockError.displayNotFound(id)
        }

        if !enabled {
            let independentActive = allDisplays.filter(\.isIndependentActive)
            if target.isIndependentActive && independentActive.count <= 1 {
                throw MonitorBlockError.cannotDisableLastActiveDisplay
            }

            // 关闭前自动保存完整布局快照，供后续恢复
            let currentSnapshot = captureCurrentLayout(from: allDisplays)
            if !currentSnapshot.isEmpty {
                preDisableSnapshots[target.uuid] = currentSnapshot
            }

            // 如果目标屏正处于镜像从属态，先解除镜像再软断开
            if target.usageMode.isMirrored {
                try backend.setMirroring(displayID: id, masterID: nil, option: .forSession)
            }

            // 如果有其他屏正在镜像本目标屏，先解除它们的镜像关系防止异常黑屏
            for follower in allDisplays where follower.mirrorMasterID == id {
                try backend.setMirroring(displayID: follower.id, masterID: nil, option: .forSession)
            }
        }

        try backend.setDisplayEnabled(id, enabled: enabled, option: .forSession)

        var record = cache[id] ?? CachedDisplayRecord(
            id: target.id,
            uuid: target.uuid,
            name: target.systemName,
            width: target.width,
            height: target.height,
            disabledByApp: !enabled,
            isBuiltin: target.isBuiltin
        )
        record.disabledByApp = !enabled
        record.isBuiltin = target.isBuiltin
        cache[id] = record
        persist()

        if !enabled {
            if let rule = disableRules[target.uuid], !rule.layoutOnDisable.isEmpty {
                try? applyLayout(rule.layoutOnDisable)
            }
        } else {
            let shouldRestore = disableRules[target.uuid]?.restorePreviousOnEnable ?? true
            if shouldRestore, let snapshot = preDisableSnapshots[target.uuid], !snapshot.isEmpty {
                try? applyLayout(snapshot)
                preDisableSnapshots.removeValue(forKey: target.uuid)
                persist()
            }
        }
    }

    public func setExternalDisplay(id: CGDirectDisplayID, enabled: Bool) throws {
        try setDisplay(id: id, enabled: enabled)
    }

    // MARK: - Usage Mode Switching (Main / Extended / Mirrored)

    /// 将指定显示器设为「主屏幕」（带菜单栏/Dock）
    public func setAsMainDisplay(id: CGDirectDisplayID) throws {
        let allDisplays = listDisplays(includeBuiltin: true)
        guard let target = allDisplays.first(where: { $0.id == id }) else {
            throw MonitorBlockError.displayNotFound(id)
        }

        if target.usageMode == .disabled {
            try setDisplay(id: id, enabled: true)
        }
        if target.usageMode.isMirrored {
            try backend.setMirroring(displayID: id, masterID: nil, option: .forSession)
        }

        // 重新读取当前独立活跃布局并将目标屏归一化至 (0, 0)
        try setMainDisplay(uuid: target.uuid)
    }

    /// 将指定显示器设为「拓展显示器」（独立非主屏桌面）
    public func setAsExtendedDisplay(id: CGDirectDisplayID) throws {
        let allDisplays = listDisplays(includeBuiltin: true)
        guard let target = allDisplays.first(where: { $0.id == id }) else {
            throw MonitorBlockError.displayNotFound(id)
        }

        if target.usageMode == .disabled {
            try setDisplay(id: id, enabled: true)
            return
        }

        if target.usageMode.isMirrored {
            try backend.setMirroring(displayID: id, masterID: nil, option: .forSession)
            return
        }

        if target.usageMode == .extended {
            return
        }

        // 目标当前是主屏：将另一块独立活跃屏（优先内置屏）提升为主屏，使目标变为拓展屏
        let otherIndependents = allDisplays.filter { $0.id != id && $0.isIndependentActive }
        guard let nextMain = otherIndependents.first(where: \.isBuiltin) ?? otherIndependents.first else {
            throw MonitorBlockError.cannotUnsetOnlyMainDisplay
        }
        try setMainDisplay(uuid: nextMain.uuid)
    }

    /// 将指定显示器设为「镜像屏幕」，镜像目标源显示器 masterID
    public func setMirrorDisplay(id: CGDirectDisplayID, masterID: CGDirectDisplayID) throws {
        guard id != masterID else {
            throw MonitorBlockError.cannotMirrorDisplayToItself
        }

        let allDisplays = listDisplays(includeBuiltin: true)
        guard let target = allDisplays.first(where: { $0.id == id }) else {
            throw MonitorBlockError.displayNotFound(id)
        }
        guard let rawMaster = allDisplays.first(where: { $0.id == masterID }),
              rawMaster.isEnabledForDisplay else {
            throw MonitorBlockError.invalidMirrorMaster(masterID)
        }

        // 如果选中的源屏幕本身正在镜像别的屏幕，自动追踪到其根源屏幕，避免链式镜像失败
        let resolvedMasterID = rawMaster.mirrorMasterID ?? rawMaster.id
        guard resolvedMasterID != id else {
            throw MonitorBlockError.cannotMirrorDisplayToItself
        }

        if target.usageMode == .disabled {
            try setDisplay(id: id, enabled: true)
        }

        // 如果有其他屏幕正在镜像 target，先转到 resolvedMasterID 或解除，防止循环依赖
        for follower in allDisplays where follower.mirrorMasterID == id && follower.id != resolvedMasterID {
            try backend.setMirroring(displayID: follower.id, masterID: resolvedMasterID, option: .forSession)
        }

        // 如果目标屏当前是主屏，先将 resolvedMasterID 提升为主屏，保证切换平滑
        if target.usageMode == .main,
           let masterInfo = listDisplays(includeBuiltin: true).first(where: { $0.id == resolvedMasterID }),
           masterInfo.isIndependentActive {
            try? setMainDisplay(uuid: masterInfo.uuid)
        }

        try backend.setMirroring(displayID: id, masterID: resolvedMasterID, option: .forSession)
    }

    /// 一键取消所有屏幕的镜像关系，全部恢复为独立拓展屏
    @discardableResult
    public func stopAllMirroring() throws -> [CGDirectDisplayID] {
        let mirrored = listDisplays(includeBuiltin: true).filter { $0.usageMode.isMirrored }
        var unmirrored: [CGDirectDisplayID] = []
        for display in mirrored {
            try backend.setMirroring(displayID: display.id, masterID: nil, option: .forSession)
            unmirrored.append(display.id)
        }
        return unmirrored
    }

    /// 紧急安全兜底：如果所有外接屏都断开/不可用，且内置屏处于被停用状态，立即恢复内置屏防止黑屏锁死
    public func ensureBuiltinActiveIfNoExternalActive() {
        let allDisplays = listDisplays(includeBuiltin: true)
        let enabledExternals = allDisplays.filter { !$0.isBuiltin && $0.isEnabledForDisplay }
        guard enabledExternals.isEmpty else { return }

        let disabledBuiltins = allDisplays.filter { $0.isBuiltin && $0.usageMode == .disabled }
        for builtin in disabledBuiltins {
            try? setDisplay(id: builtin.id, enabled: true)
        }
    }

    /// 恢复全部处于停用状态的显示器（含内置屏与外接屏）
    @discardableResult
    public func enableAllDisplays() throws -> [CGDirectDisplayID] {
        let all = listDisplays(includeBuiltin: true)
        let toEnable = all.filter { $0.usageMode == .disabled || $0.disabledByApp }
        var enabledIDs: [CGDirectDisplayID] = []
        var firstError: Error?

        for display in toEnable {
            do {
                try setDisplay(id: display.id, enabled: true)
                enabledIDs.append(display.id)
            } catch {
                if var record = cache[display.id] {
                    record.disabledByApp = false
                    cache[display.id] = record
                    persist()
                }
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if enabledIDs.isEmpty, let firstError {
            throw firstError
        }
        return enabledIDs
    }

    /// 切换指定显示器（内置或外接）开关状态
    public func toggleDisplay(id: CGDirectDisplayID) throws {
        let displays = listDisplays(includeBuiltin: true)
        guard let target = displays.first(where: { $0.id == id }) else {
            throw MonitorBlockError.displayNotFound(id)
        }
        try setDisplay(id: id, enabled: !target.isEnabledForDisplay)
    }

    @discardableResult
    public func disableAllExternal() throws -> [CGDirectDisplayID] {
        let allDisplays = listDisplays(includeBuiltin: true)
        let externalsToDisable = allDisplays.filter { !$0.isBuiltin && $0.isEnabledForDisplay }
        guard !externalsToDisable.isEmpty else { return [] }

        let activeBuiltinCount = allDisplays.filter { $0.isBuiltin && $0.isIndependentActive }.count
        if activeBuiltinCount == 0 {
            throw MonitorBlockError.cannotDisableLastActiveDisplay
        }

        var disabledIDs: [CGDirectDisplayID] = []
        for display in externalsToDisable {
            try setDisplay(id: display.id, enabled: false)
            disabledIDs.append(display.id)
        }
        return disabledIDs
    }

    @discardableResult
    public func enableAllExternal() throws -> [CGDirectDisplayID] {
        let externals = listDisplays(includeBuiltin: false)
        let toEnable = externals.filter { $0.usageMode == .disabled || $0.disabledByApp }
        var enabledIDs: [CGDirectDisplayID] = []
        var firstError: Error?

        for display in toEnable {
            do {
                try setDisplay(id: display.id, enabled: true)
                enabledIDs.append(display.id)
            } catch {
                if var record = cache[display.id] {
                    record.disabledByApp = false
                    cache[display.id] = record
                    persist()
                }
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if enabledIDs.isEmpty, let firstError {
            throw firstError
        }
        return enabledIDs
    }

    public func toggleExternal(id: CGDirectDisplayID? = nil) throws {
        if let id {
            let displays = listDisplays(includeBuiltin: true)
            guard let target = displays.first(where: { $0.id == id }) else {
                throw MonitorBlockError.displayNotFound(id)
            }
            try setDisplay(id: id, enabled: !target.isEnabledForDisplay)
            return
        }

        let externals = listDisplays(includeBuiltin: false)
        let hasEnabledExternal = externals.contains(where: \.isEnabledForDisplay)
        if hasEnabledExternal {
            try disableAllExternal()
        } else {
            try enableAllExternal()
        }
    }

    // MARK: - Layout Arrangement

    public func captureCurrentLayout() -> [DisplayPlacement] {
        captureCurrentLayout(from: listDisplays(includeBuiltin: true))
    }

    private func captureCurrentLayout(from displays: [DisplayInfo]) -> [DisplayPlacement] {
        displays
            .filter(\.isIndependentActive)
            .map {
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
    }

    /// 将一组布局坐标归一化（主屏归零至 (0,0)）并应用到当前匹配的独立活跃显示器
    public func applyLayout(_ placements: [DisplayPlacement]) throws {
        let activeDisplays = listDisplays(includeBuiltin: true).filter(\.isIndependentActive)
        let byUUID = Dictionary(uniqueKeysWithValues: activeDisplays.map { ($0.uuid, $0) })

        let matched = placements.compactMap { placement -> (DisplayPlacement, DisplayInfo)? in
            guard let info = byUUID[placement.uuid] else { return nil }
            return (placement, info)
        }

        guard !matched.isEmpty else {
            throw MonitorBlockError.noMatchingActiveDisplaysForLayout
        }

        let mainEntry = matched.first(where: { $0.0.isMain }) ?? matched[0]
        let offsetX = mainEntry.0.x
        let offsetY = mainEntry.0.y

        let updates = matched.map { (placement, info) in
            DisplayOriginUpdate(
                displayID: info.id,
                x: Int32(placement.x - offsetX),
                y: Int32(placement.y - offsetY)
            )
        }

        try backend.applyLayout(updates, option: .forSession)
    }

    /// 将指定 UUID 的独立活跃显示器设为主屏，其余屏幕保持原有相对位置
    public func setMainDisplay(uuid: String) throws {
        var current = captureCurrentLayout()
        guard let idx = current.firstIndex(where: { $0.uuid == uuid }) else {
            throw MonitorBlockError.displayUUIDNotFound(uuid)
        }
        for i in current.indices {
            current[i].isMain = (i == idx)
        }
        try applyLayout(current)
    }

    // MARK: - Presets CRUD

    public func listPresets() -> [LayoutPreset] {
        presets
    }

    @discardableResult
    public func savePreset(name: String, placements: [DisplayPlacement]? = nil) -> LayoutPreset {
        let resolvedPlacements = placements ?? captureCurrentLayout()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "布局 \(presets.count + 1)" : trimmed

        if let existingIdx = presets.firstIndex(where: { $0.name == finalName }) {
            presets[existingIdx].placements = resolvedPlacements
            persist()
            return presets[existingIdx]
        }

        let preset = LayoutPreset(name: finalName, placements: resolvedPlacements)
        presets.append(preset)
        persist()
        return preset
    }

    public func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    public func applyPreset(id: UUID) throws {
        guard let preset = presets.first(where: { $0.id == id }) else {
            throw MonitorBlockError.presetNotFound(id)
        }
        try applyLayout(preset.placements)
    }

    // MARK: - Disable Rules CRUD

    public func listDisableRules() -> [DisableLayoutRule] {
        disableRules.values.sorted { $0.targetDisplayName < $1.targetDisplayName }
    }

    public func disableRule(forDisplayUUID uuid: String) -> DisableLayoutRule? {
        disableRules[uuid]
    }

    public func saveDisableRule(_ rule: DisableLayoutRule) {
        disableRules[rule.targetDisplayUUID] = rule
        persist()
    }

    public func deleteDisableRule(forDisplayUUID uuid: String) {
        disableRules.removeValue(forKey: uuid)
        persist()
    }

    // MARK: - Custom Display Naming

    public func customName(forDisplayUUID uuid: String) -> String? {
        customNames[uuid]
    }

    /// 设置或清除（传 nil/空串）指定显示器的自定义名称，同步刷新规则与预设中的显示名
    public func setCustomName(_ name: String?, forDisplayUUID uuid: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customNames.removeValue(forKey: uuid)
        } else {
            customNames[uuid] = trimmed
        }

        let latestName = listDisplays(includeBuiltin: true).first(where: { $0.uuid == uuid })?.name
            ?? (trimmed.isEmpty ? nil : trimmed)

        if let latestName {
            for pIdx in presets.indices {
                for idx in presets[pIdx].placements.indices where presets[pIdx].placements[idx].uuid == uuid {
                    presets[pIdx].placements[idx].name = latestName
                }
            }
            for (ruleKey, var rule) in disableRules {
                var modified = false
                if rule.targetDisplayUUID == uuid {
                    rule.targetDisplayName = latestName
                    modified = true
                }
                for idx in rule.layoutOnDisable.indices where rule.layoutOnDisable[idx].uuid == uuid {
                    rule.layoutOnDisable[idx].name = latestName
                    modified = true
                }
                if modified {
                    disableRules[ruleKey] = rule
                }
            }
        }

        persist()
    }

    // MARK: - Reconfiguration Observation

    public func startObservingReconfiguration(_ handler: @escaping @Sendable () -> Void) {
        backend.startObservingReconfiguration(handler)
    }

    public func stopObservingReconfiguration() {
        backend.stopObservingReconfiguration()
    }
}
