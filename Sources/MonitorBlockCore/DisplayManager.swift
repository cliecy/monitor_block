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
        var results: [DisplayInfo] = []
        var cacheChanged = false

        for snap in snapshots {
            liveIDs.insert(snap.id)

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

            let resolvedWidth = snap.width > 0 ? snap.width : (existing?.width ?? 0)
            let resolvedHeight = snap.height > 0 ? snap.height : (existing?.height ?? 0)

            var disabledByApp = existing?.disabledByApp ?? false
            if snap.isActive && disabledByApp {
                disabledByApp = false
                cacheChanged = true
            }

            let updated = CachedDisplayRecord(
                id: snap.id,
                uuid: snap.uuid,
                name: systemName,
                width: resolvedWidth,
                height: resolvedHeight,
                disabledByApp: disabledByApp,
                isBuiltin: snap.isBuiltin
            )
            if cache[snap.id] != updated {
                cache[snap.id] = updated
                cacheChanged = true
            }

            if includeBuiltin || !snap.isBuiltin {
                results.append(
                    DisplayInfo(
                        id: snap.id,
                        uuid: snap.uuid,
                        serialNumber: snap.serialNumber,
                        name: resolvedName,
                        systemName: systemName,
                        customName: customName,
                        isBuiltin: snap.isBuiltin,
                        isActive: snap.isActive,
                        isOnline: snap.isOnline,
                        originX: snap.originX,
                        originY: snap.originY,
                        width: resolvedWidth,
                        height: resolvedHeight,
                        isMain: snap.isMain,
                        disabledByApp: disabledByApp
                    )
                )
            }
        }

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

    /// 启用或停用任意显示器（支持内置屏与外接屏，但严格禁止停用最后一块活跃屏）
    public func setDisplay(id: CGDirectDisplayID, enabled: Bool) throws {
        let allDisplays = listDisplays(includeBuiltin: true)
        guard let target = allDisplays.first(where: { $0.id == id }) else {
            throw MonitorBlockError.displayNotFound(id)
        }

        if !enabled {
            let activeCount = allDisplays.filter(\.isActive).count
            if target.isActive && activeCount <= 1 {
                throw MonitorBlockError.cannotDisableLastActiveDisplay
            }
            // 关闭前自动保存完整布局快照，供后续恢复
            let currentSnapshot = captureCurrentLayout(from: allDisplays)
            if !currentSnapshot.isEmpty {
                preDisableSnapshots[target.uuid] = currentSnapshot
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
            // 如果为该屏幕配置了“关闭后布局规则”，自动应用到剩余活跃屏幕
            if let rule = disableRules[target.uuid], !rule.layoutOnDisable.isEmpty {
                try? applyLayout(rule.layoutOnDisable)
            }
        } else {
            // 如果开启了“重新启用时恢复原布局”，则自动还原关闭前的布局
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

    /// 紧急安全兜底：如果所有外接屏都断开/不可用，且内置屏处于被停用状态，立即恢复内置屏防止黑屏锁死
    public func ensureBuiltinActiveIfNoExternalActive() {
        let allDisplays = listDisplays(includeBuiltin: true)
        let activeExternals = allDisplays.filter { !$0.isBuiltin && $0.isActive }
        guard activeExternals.isEmpty else { return }

        let disabledBuiltins = allDisplays.filter { $0.isBuiltin && (!$0.isActive || $0.disabledByApp) }
        for builtin in disabledBuiltins {
            try? setDisplay(id: builtin.id, enabled: true)
        }
    }

    /// 恢复全部处于停用状态的显示器（含内置屏与外接屏）
    @discardableResult
    public func enableAllDisplays() throws -> [CGDirectDisplayID] {
        let all = listDisplays(includeBuiltin: true)
        let toEnable = all.filter { !$0.isActive || $0.disabledByApp }
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

    /// 切换指定显示器（内置或外接）状态
    public func toggleDisplay(id: CGDirectDisplayID) throws {
        let displays = listDisplays(includeBuiltin: true)
        guard let target = displays.first(where: { $0.id == id }) else {
            throw MonitorBlockError.displayNotFound(id)
        }
        try setDisplay(id: id, enabled: !target.isActive)
    }

    @discardableResult
    public func disableAllExternal() throws -> [CGDirectDisplayID] {
        let allDisplays = listDisplays(includeBuiltin: true)
        let externalsToDisable = allDisplays.filter { !$0.isBuiltin && $0.isActive }
        guard !externalsToDisable.isEmpty else { return [] }

        let activeBuiltinCount = allDisplays.filter { $0.isBuiltin && $0.isActive }.count
        if activeBuiltinCount == 0 {
            throw MonitorBlockError.cannotDisableLastActiveDisplay
        }

        var disabledIDs: [CGDirectDisplayID] = []
        for display in externalsToDisable {
            try setExternalDisplay(id: display.id, enabled: false)
            disabledIDs.append(display.id)
        }
        return disabledIDs
    }

    @discardableResult
    public func enableAllExternal() throws -> [CGDirectDisplayID] {
        let externals = listDisplays(includeBuiltin: false)
        let toEnable = externals.filter { !$0.isActive || $0.disabledByApp }
        var enabledIDs: [CGDirectDisplayID] = []
        var firstError: Error?

        for display in toEnable {
            do {
                try setExternalDisplay(id: display.id, enabled: true)
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
            try setExternalDisplay(id: id, enabled: !target.isActive)
            return
        }

        let externals = listDisplays(includeBuiltin: false)
        let hasActiveExternal = externals.contains(where: \.isActive)
        if hasActiveExternal {
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
            .filter(\.isActive)
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

    /// 将一组布局坐标归一化（主屏归零至 (0,0)）并应用到当前匹配的活跃显示器
    public func applyLayout(_ placements: [DisplayPlacement]) throws {
        let activeDisplays = listDisplays(includeBuiltin: true).filter(\.isActive)
        let byUUID = Dictionary(uniqueKeysWithValues: activeDisplays.map { ($0.uuid, $0) })

        let matched = placements.compactMap { placement -> (DisplayPlacement, DisplayInfo)? in
            guard let info = byUUID[placement.uuid] else { return nil }
            return (placement, info)
        }

        guard !matched.isEmpty else {
            throw MonitorBlockError.noMatchingActiveDisplaysForLayout
        }

        // 选择主屏作为坐标原点 (0, 0)
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

    /// 将指定 UUID 的活跃显示器设为主屏，其余屏幕保持原有相对位置
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
