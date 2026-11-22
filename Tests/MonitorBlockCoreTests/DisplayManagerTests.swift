import CoreGraphics
import Testing
@testable import MonitorBlockCore

private final class MockDisplayBackend: DisplayBackend {
    struct ToggleCall: Equatable {
        let displayID: CGDirectDisplayID
        let enabled: Bool
        let option: CGConfigureOption
    }

    struct LayoutCall: Equatable {
        let updates: [DisplayOriginUpdate]
        let option: CGConfigureOption
    }

    struct MirrorCall: Equatable {
        let displayID: CGDirectDisplayID
        let masterID: CGDirectDisplayID?
        let option: CGConfigureOption
    }

    var isPrivateAPIAvailable: Bool = true
    var displays: [RawDisplaySnapshot] = []
    var calls: [ToggleCall] = []
    var layoutCalls: [LayoutCall] = []
    var mirrorCalls: [MirrorCall] = []
    var errorToThrow: Error?
    var hideDisplayWhenDisabled: Bool = false

    func fetchDisplays() -> [RawDisplaySnapshot] {
        displays
    }

    func setDisplayEnabled(
        _ displayID: CGDirectDisplayID,
        enabled: Bool,
        option: CGConfigureOption
    ) throws {
        calls.append(ToggleCall(displayID: displayID, enabled: enabled, option: option))
        if let errorToThrow {
            throw errorToThrow
        }

        if let index = displays.firstIndex(where: { $0.id == displayID }) {
            if !enabled && hideDisplayWhenDisabled {
                displays.remove(at: index)
            } else {
                let old = displays[index]
                displays[index] = RawDisplaySnapshot(
                    id: old.id,
                    uuid: old.uuid,
                    name: old.name,
                    isBuiltin: old.isBuiltin,
                    isActive: enabled,
                    isOnline: true,
                    originX: old.originX,
                    originY: old.originY,
                    width: old.width,
                    height: old.height,
                    isMain: enabled && old.isMain
                )
            }
        } else if enabled {
            displays.append(
                RawDisplaySnapshot(
                    id: displayID,
                    uuid: "ext-uuid-\(displayID)",
                    name: "Restored Display",
                    isBuiltin: false,
                    isActive: true,
                    isOnline: true,
                    originX: 1920,
                    originY: 0,
                    width: 3840,
                    height: 2160,
                    isMain: false
                )
            )
        }
    }

    func applyLayout(
        _ updates: [DisplayOriginUpdate],
        option: CGConfigureOption
    ) throws {
        layoutCalls.append(LayoutCall(updates: updates, option: option))
        if let errorToThrow {
            throw errorToThrow
        }

        for update in updates {
            if let index = displays.firstIndex(where: { $0.id == update.displayID }) {
                let old = displays[index]
                displays[index] = RawDisplaySnapshot(
                    id: old.id,
                    uuid: old.uuid,
                    serialNumber: old.serialNumber,
                    name: old.name,
                    isBuiltin: old.isBuiltin,
                    isActive: old.isActive,
                    isOnline: old.isOnline,
                    originX: Int(update.x),
                    originY: Int(update.y),
                    width: old.width,
                    height: old.height,
                    isMain: (update.x == 0 && update.y == 0),
                    mirrorMasterID: old.mirrorMasterID
                )
            }
        }
    }

    func setMirroring(
        displayID: CGDirectDisplayID,
        masterID: CGDirectDisplayID?,
        option: CGConfigureOption
    ) throws {
        mirrorCalls.append(MirrorCall(displayID: displayID, masterID: masterID, option: option))
        if let errorToThrow {
            throw errorToThrow
        }
        if let index = displays.firstIndex(where: { $0.id == displayID }) {
            let old = displays[index]
            // 在真实 macOS 中，镜像从属屏不在 ActiveDisplayList 中（isActive = false），但 online 且 mirrorMasterID != nil
            let becomingMirrored = (masterID != nil)
            displays[index] = RawDisplaySnapshot(
                id: old.id,
                uuid: old.uuid,
                serialNumber: old.serialNumber,
                name: old.name,
                isBuiltin: old.isBuiltin,
                isActive: !becomingMirrored,
                isOnline: true,
                originX: old.originX,
                originY: old.originY,
                width: old.width,
                height: old.height,
                isMain: becomingMirrored ? false : old.isMain,
                mirrorMasterID: masterID
            )
        }
    }

    func startObservingReconfiguration(_ handler: @escaping @Sendable () -> Void) {}
    func stopObservingReconfiguration() {}
}

@Suite("DisplayManager Tests")
struct DisplayManagerTests {
    private func makeBuiltin(
        id: CGDirectDisplayID = 1,
        active: Bool = true,
        x: Int = 0,
        y: Int = 0,
        isMain: Bool = true
    ) -> RawDisplaySnapshot {
        RawDisplaySnapshot(
            id: id,
            uuid: "builtin-uuid",
            name: "Built-in Retina Display",
            isBuiltin: true,
            isActive: active,
            isOnline: true,
            originX: x,
            originY: y,
            width: 1512,
            height: 982,
            isMain: isMain
        )
    }

    private func makeExternal(
        id: CGDirectDisplayID = 2,
        name: String? = "DELL U2723QE",
        active: Bool = true,
        x: Int = 1512,
        y: Int = 0,
        isMain: Bool = false
    ) -> RawDisplaySnapshot {
        RawDisplaySnapshot(
            id: id,
            uuid: "ext-uuid-\(id)",
            name: name,
            isBuiltin: false,
            isActive: active,
            isOnline: true,
            originX: x,
            originY: y,
            width: 2560,
            height: 1440,
            isMain: isMain
        )
    }

    @Test("禁用与重新启用外接显示器严格使用 forSession")
    func disableAndEnableExternalUsesSessionOption() throws {
        let backend = MockDisplayBackend()
        backend.displays = [makeBuiltin(), makeExternal(id: 2)]
        let store = InMemoryStateStore()
        let manager = DisplayManager(backend: backend, store: store)

        try manager.setExternalDisplay(id: 2, enabled: false)

        #expect(backend.calls.count == 1)
        #expect(backend.calls[0].displayID == 2)
        #expect(backend.calls[0].enabled == false)
        #expect(backend.calls[0].option == .forSession)

        let afterDisable = manager.listDisplays(includeBuiltin: false)
        #expect(afterDisable.count == 1)
        #expect(afterDisable[0].isActive == false)
        #expect(afterDisable[0].disabledByApp == true)

        try manager.setExternalDisplay(id: 2, enabled: true)
        #expect(backend.calls.count == 2)
        #expect(backend.calls[1].enabled == true)
        #expect(backend.calls[1].option == .forSession)

        let afterEnable = manager.listDisplays(includeBuiltin: false)
        #expect(afterEnable[0].isActive == true)
        #expect(afterEnable[0].disabledByApp == false)
    }

    @Test("允许在有活跃外接屏时停用内置屏，但外接屏全部断开后自动恢复内置屏")
    func canDisableBuiltinWhenExternalActiveAndAutoRecoverWhenUnplugged() throws {
        let backend = MockDisplayBackend()
        backend.displays = [makeBuiltin(id: 1, active: true), makeExternal(id: 2, active: true)]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        // 有活跃外接屏时，允许关闭内置屏
        try manager.setDisplay(id: 1, enabled: false)
        #expect(backend.calls.last?.displayID == 1)
        #expect(backend.calls.last?.enabled == false)
        #expect(manager.listDisplays(includeBuiltin: true).first(where: { $0.id == 1 })?.isActive == false)

        // 模拟外接屏被拔出 -> 安全兜底应立即恢复内置屏
        backend.displays.removeAll { $0.id == 2 }
        manager.ensureBuiltinActiveIfNoExternalActive()
        #expect(backend.calls.last?.displayID == 1)
        #expect(backend.calls.last?.enabled == true)
    }

    @Test("为两台同型号显示器设置独立自定义名称并持久化同步")
    func customNamingDistinguishesIdenticalMonitors() {
        let backend = MockDisplayBackend()
        backend.displays = [
            makeBuiltin(id: 1),
            makeExternal(id: 2, name: "LG UltraFine"),
            makeExternal(id: 3, name: "LG UltraFine")
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        manager.setCustomName("左 LG（主屏）", forDisplayUUID: "ext-uuid-2")
        manager.setCustomName("右 LG（副屏）", forDisplayUUID: "ext-uuid-3")

        let externals = manager.listDisplays(includeBuiltin: false)
        let left = externals.first(where: { $0.uuid == "ext-uuid-2" })
        let right = externals.first(where: { $0.uuid == "ext-uuid-3" })

        #expect(left?.name == "左 LG（主屏）")
        #expect(left?.systemName == "LG UltraFine")
        #expect(right?.name == "右 LG（副屏）")

        // 清空自定义名应恢复系统原名
        manager.setCustomName("", forDisplayUUID: "ext-uuid-2")
        let reset = manager.listDisplays(includeBuiltin: false).first(where: { $0.uuid == "ext-uuid-2" })
        #expect(reset?.name == "LG UltraFine")
        #expect(reset?.customName == nil)
    }

    @Test("合盖模式下禁止停用最后一块活跃外接屏")
    func cannotDisableLastActiveDisplayInClamshellMode() {
        let backend = MockDisplayBackend()
        backend.displays = [
            makeBuiltin(id: 1, active: false, isMain: false),
            makeExternal(id: 2, active: true, x: 0, y: 0, isMain: true)
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        #expect(throws: MonitorBlockError.cannotDisableLastActiveDisplay) {
            try manager.setExternalDisplay(id: 2, enabled: false)
        }
        #expect(backend.calls.isEmpty)

        #expect(throws: MonitorBlockError.cannotDisableLastActiveDisplay) {
            try manager.disableAllExternal()
        }
        #expect(backend.calls.isEmpty)
    }

    @Test("停用后从系统在线列表消失的外接屏仍可通过缓存找回并恢复")
    func disabledDisplayRemovedFromOnlineListRemainsRecoverableViaCache() throws {
        let backend = MockDisplayBackend()
        backend.hideDisplayWhenDisabled = true
        backend.displays = [makeBuiltin(id: 1), makeExternal(id: 2, name: "LG UltraFine")]
        let store = InMemoryStateStore()
        let manager = DisplayManager(backend: backend, store: store)

        _ = manager.listDisplays(includeBuiltin: false)
        try manager.setExternalDisplay(id: 2, enabled: false)

        let listed = manager.listDisplays(includeBuiltin: false)
        #expect(listed.count == 1)
        #expect(listed[0].id == 2)
        #expect(listed[0].name == "LG UltraFine")
        #expect(listed[0].isActive == false)
        #expect(listed[0].disabledByApp == true)

        try manager.enableAllExternal()
        #expect(backend.calls.last?.displayID == 2)
        #expect(backend.calls.last?.enabled == true)
    }

    @Test("多外接屏下的批量停用、恢复与单屏切换")
    func toggleAndBatchOperationsWithMultipleExternals() throws {
        let backend = MockDisplayBackend()
        backend.displays = [
            makeBuiltin(id: 1),
            makeExternal(id: 2, name: "Monitor A", active: true),
            makeExternal(id: 3, name: "Monitor B", active: true)
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        let disabled = try manager.disableAllExternal()
        #expect(Set(disabled) == [2, 3])
        #expect(manager.listDisplays(includeBuiltin: false).allSatisfy { !$0.isActive })

        try manager.toggleExternal()
        #expect(manager.listDisplays(includeBuiltin: false).allSatisfy { $0.isActive })

        try manager.toggleExternal(id: 3)
        let externals = manager.listDisplays(includeBuiltin: false)
        #expect(externals.first(where: { $0.id == 2 })?.isActive == true)
        #expect(externals.first(where: { $0.id == 3 })?.isActive == false)
    }

    @Test("底层 API 报错时不污染缓存状态")
    func backendFailureDoesNotPolluteCache() {
        let backend = MockDisplayBackend()
        backend.displays = [makeBuiltin(id: 1), makeExternal(id: 2)]
        backend.errorToThrow = MonitorBlockError.configurationFailed(1000)
        let store = InMemoryStateStore()
        let manager = DisplayManager(backend: backend, store: store)

        #expect(throws: MonitorBlockError.configurationFailed(1000)) {
            try manager.setExternalDisplay(id: 2, enabled: false)
        }

        let listed = manager.listDisplays(includeBuiltin: false)
        #expect(listed.count == 1)
        #expect(listed[0].isActive == true)
        #expect(listed[0].disabledByApp == false)
    }

    @Test("修改布局与主屏归一化坐标")
    func applyLayoutNormalizesMainDisplayToOrigin() throws {
        let backend = MockDisplayBackend()
        backend.displays = [
            makeBuiltin(id: 1, x: 0, y: 0, isMain: true),
            makeExternal(id: 2, name: "Main Ext", x: 1512, y: 0, isMain: false)
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        // 将外接屏设为主屏，内置屏保持在其左侧
        try manager.setMainDisplay(uuid: "ext-uuid-2")

        let lastLayout = try #require(backend.layoutCalls.last)
        #expect(lastLayout.option == .forSession)
        #expect(lastLayout.updates.first(where: { $0.displayID == 2 }) == DisplayOriginUpdate(displayID: 2, x: 0, y: 0))
        #expect(lastLayout.updates.first(where: { $0.displayID == 1 }) == DisplayOriginUpdate(displayID: 1, x: -1512, y: 0))
    }

    @Test("关闭指定外接屏自动应用关闭后布局规则，重新启用后自动恢复原布局")
    func disableRuleAppliesOnDisableAndRestoresOnEnable() throws {
        let backend = MockDisplayBackend()
        // 三屏场景：内置屏在左 (-1512, 0)，外接屏2在中主屏 (0, 0)，外接屏3在右 (2560, 0)
        backend.displays = [
            makeBuiltin(id: 1, x: -1512, y: 0, isMain: false),
            makeExternal(id: 2, name: "Center", x: 0, y: 0, isMain: true),
            makeExternal(id: 3, name: "Right", x: 2560, y: 0, isMain: false)
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        // 规则：关闭中间屏2后，让右屏3变主屏(0,0)，内置屏1放到右屏3下方(500, 1440)
        let rule = DisableLayoutRule(
            targetDisplayUUID: "ext-uuid-2",
            targetDisplayName: "Center",
            layoutOnDisable: [
                DisplayPlacement(uuid: "ext-uuid-3", name: "Right", x: 0, y: 0, width: 2560, height: 1440, isMain: true),
                DisplayPlacement(uuid: "builtin-uuid", name: "Built-in", x: 500, y: 1440, width: 1512, height: 982, isMain: false)
            ],
            restorePreviousOnEnable: true
        )
        manager.saveDisableRule(rule)

        // 1. 关闭中间屏 2 -> 应自动触发规则布局
        try manager.setExternalDisplay(id: 2, enabled: false)

        let onDisableLayout = try #require(backend.layoutCalls.last)
        #expect(onDisableLayout.updates.first(where: { $0.displayID == 3 }) == DisplayOriginUpdate(displayID: 3, x: 0, y: 0))
        #expect(onDisableLayout.updates.first(where: { $0.displayID == 1 }) == DisplayOriginUpdate(displayID: 1, x: 500, y: 1440))

        // 2. 重新开启中间屏 2 -> 应自动恢复关闭前的三屏布局
        try manager.setExternalDisplay(id: 2, enabled: true)

        let onEnableLayout = try #require(backend.layoutCalls.last)
        #expect(onEnableLayout.updates.first(where: { $0.displayID == 2 }) == DisplayOriginUpdate(displayID: 2, x: 0, y: 0))
        #expect(onEnableLayout.updates.first(where: { $0.displayID == 1 }) == DisplayOriginUpdate(displayID: 1, x: -1512, y: 0))
        #expect(onEnableLayout.updates.first(where: { $0.displayID == 3 }) == DisplayOriginUpdate(displayID: 3, x: 2560, y: 0))
    }

    @Test("保存、应用与删除布局预设")
    func layoutPresetCRUD() throws {
        let backend = MockDisplayBackend()
        backend.displays = [
            makeBuiltin(id: 1, x: 0, y: 0, isMain: true),
            makeExternal(id: 2, name: "DELL", x: 1512, y: 0, isMain: false)
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        let customPlacements = [
            DisplayPlacement(uuid: "builtin-uuid", name: "Built-in", x: 0, y: 0, width: 1512, height: 982, isMain: true),
            DisplayPlacement(uuid: "ext-uuid-2", name: "DELL", x: -2560, y: 0, width: 2560, height: 1440, isMain: false)
        ]
        let preset = manager.savePreset(name: "左侧外接", placements: customPlacements)
        #expect(manager.listPresets().count == 1)

        try manager.applyPreset(id: preset.id)
        let applied = try #require(backend.layoutCalls.last)
        #expect(applied.updates.first(where: { $0.displayID == 2 }) == DisplayOriginUpdate(displayID: 2, x: -2560, y: 0))

        manager.deletePreset(id: preset.id)
        #expect(manager.listPresets().isEmpty)
    }

    @Test("每台显示器独立切换主屏幕、拓展显示器与镜像屏幕模式")
    func switchDisplayBetweenMainExtendedAndMirrored() throws {
        let backend = MockDisplayBackend()
        backend.displays = [
            makeBuiltin(id: 1, x: 0, y: 0, isMain: true),
            makeExternal(id: 2, name: "LG Left", x: 1512, y: 0, isMain: false),
            makeExternal(id: 3, name: "LG Right", x: 4072, y: 0, isMain: false)
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        // 1. 将右 LG 镜像到左 LG
        try manager.setMirrorDisplay(id: 3, masterID: 2)
        #expect(backend.mirrorCalls.last == MockDisplayBackend.MirrorCall(displayID: 3, masterID: 2, option: .forSession))

        let afterMirror = manager.listDisplays(includeBuiltin: true)
        let mirroredRight = try #require(afterMirror.first(where: { $0.id == 3 }))
        #expect(mirroredRight.usageMode == .mirrored(masterID: 2, masterUUID: "ext-uuid-2", masterName: "LG Left"))
        #expect(mirroredRight.isEnabledForDisplay == true)

        // 2. 将镜像中的右 LG 直接设为主屏幕 -> 自动先解除镜像再设为主屏 (0, 0)
        try manager.setAsMainDisplay(id: 3)
        #expect(backend.mirrorCalls.last == MockDisplayBackend.MirrorCall(displayID: 3, masterID: nil, option: .forSession))
        #expect(backend.layoutCalls.last?.updates.first(where: { $0.displayID == 3 }) == DisplayOriginUpdate(displayID: 3, x: 0, y: 0))

        // 3. 将当前主屏右 LG 改为拓展显示器 -> 自动将内置屏提升为主屏
        try manager.setAsExtendedDisplay(id: 3)
        let afterExtended = manager.listDisplays(includeBuiltin: true)
        #expect(afterExtended.first(where: { $0.id == 1 })?.usageMode == .main)
        #expect(afterExtended.first(where: { $0.id == 3 })?.usageMode == .extended)
    }

    @Test("禁止自镜像、禁止取消唯一主屏身份，且停用镜像从属屏时先解除镜像")
    func mirrorSafetyGuardsAndStopAllMirroring() throws {
        let backend = MockDisplayBackend()
        backend.displays = [
            makeBuiltin(id: 1, x: 0, y: 0, isMain: true),
            makeExternal(id: 2, name: "LG", x: 1512, y: 0, isMain: false)
        ]
        let manager = DisplayManager(backend: backend, store: InMemoryStateStore())

        // 禁止镜像自己
        #expect(throws: MonitorBlockError.cannotMirrorDisplayToItself) {
            try manager.setMirrorDisplay(id: 2, masterID: 2)
        }

        // 设为镜像后，内置屏是唯一独立主屏 -> 禁止将内置屏改为拓展
        try manager.setMirrorDisplay(id: 2, masterID: 1)
        #expect(throws: MonitorBlockError.cannotUnsetOnlyMainDisplay) {
            try manager.setAsExtendedDisplay(id: 1)
        }

        // 停用镜像从属屏 2 -> 应先解除镜像再软断开，不误触发最后一块屏拦截
        try manager.setDisplay(id: 2, enabled: false)
        #expect(backend.mirrorCalls.last == MockDisplayBackend.MirrorCall(displayID: 2, masterID: nil, option: .forSession))
        #expect(backend.calls.last?.displayID == 2)
        #expect(backend.calls.last?.enabled == false)

        // 重新启用并再次镜像后，一键取消全部镜像
        try manager.setDisplay(id: 2, enabled: true)
        try manager.setMirrorDisplay(id: 2, masterID: 1)
        let unmirrored = try manager.stopAllMirroring()
        #expect(unmirrored == [2])
        #expect(manager.listDisplays(includeBuiltin: true).allSatisfy { !$0.usageMode.isMirrored })
    }
}
