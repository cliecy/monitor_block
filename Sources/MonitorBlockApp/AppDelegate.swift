import AppKit
import CoreGraphics
import Foundation
import MonitorBlockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let autoRestoreKey = "MonitorBlock.autoRestoreOnQuit"

    private let manager = DisplayManager()
    private let launchAtLogin = LaunchAtLoginManager()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var layoutEditorController: LayoutEditorWindowController?
    private var wakeObserver: NSObjectProtocol?
    private var pendingRefreshWorkItem: DispatchWorkItem?

    private var autoRestoreOnQuit: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.autoRestoreKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.autoRestoreKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoRestoreKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu

        refreshUI()

        manager.startObservingReconfiguration { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh(checkSafetyFallback: true)
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh(delay: 0.6, checkSafetyFallback: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopObservingReconfiguration()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if autoRestoreOnQuit {
            _ = try? manager.enableAllDisplays()
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    // MARK: - UI Refresh

    private func scheduleRefresh(delay: TimeInterval = 0.25, checkSafetyFallback: Bool = false) {
        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if checkSafetyFallback {
                self.manager.ensureBuiltinActiveIfNoExternalActive()
            }
            self.refreshUI()
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshUI() {
        let allDisplays = manager.listDisplays(includeBuiltin: true)
        updateStatusIcon(displays: allDisplays)
        rebuildMenu(displays: allDisplays)
    }

    private func updateStatusIcon(displays: [DisplayInfo]) {
        guard let button = statusItem.button else { return }
        let externals = displays.filter { !$0.isBuiltin }
        let activeCount = displays.filter(\.isActive).count

        let symbolName: String
        let tooltip: String

        if externals.isEmpty {
            symbolName = "laptopcomputer"
            tooltip = "MonitorBlock：仅内置显示器"
        } else if activeCount > 1 {
            symbolName = "display.2"
            tooltip = "MonitorBlock：多屏使用中（\(activeCount) 块活跃）"
        } else if externals.contains(where: \.isActive) {
            symbolName = "display"
            tooltip = "MonitorBlock：仅外接显示器使用中（内置屏已停用）"
        } else {
            symbolName = "laptopcomputer"
            tooltip = "MonitorBlock：外接显示器已停用"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MonitorBlock")
        image?.isTemplate = true
        button.image = image
        button.toolTip = tooltip
    }

    private func rebuildMenu(displays: [DisplayInfo]) {
        menu.removeAllItems()

        if !manager.isPrivateAPIAvailable {
            let warning = NSMenuItem(
                title: "⚠️ 当前系统不支持软断开 API",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: "显示器开关（点击启用/停用）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if displays.isEmpty {
            let emptyItem = NSMenuItem(title: "  未检测到显示器", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for display in displays {
                var title = display.name
                if display.isBuiltin {
                    title += " [内置]"
                }
                if let res = display.resolutionText {
                    title += "  (\(res))"
                }
                if !display.isActive {
                    title += " [已停用]"
                } else if display.isMain {
                    title += " ★"
                }
                if manager.disableRule(forDisplayUUID: display.uuid) != nil {
                    title += " • 已配关闭规则"
                }

                let item = NSMenuItem(
                    title: title,
                    action: #selector(toggleSingleDisplay(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.state = display.isActive ? .on : .off
                item.representedObject = NSNumber(value: display.id)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let identifyItem = NSMenuItem(
            title: "识别显示器（屏幕闪显名称）",
            action: #selector(identifyAllDisplays),
            keyEquivalent: "i"
        )
        identifyItem.target = self
        menu.addItem(identifyItem)

        // 布局预设子菜单
        let presetsMenu = NSMenu()
        let presets = manager.listPresets()
        if presets.isEmpty {
            let noneItem = NSMenuItem(title: "暂无已保存的预设", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            presetsMenu.addItem(noneItem)
        } else {
            for preset in presets {
                let presetItem = NSMenuItem(
                    title: preset.name,
                    action: #selector(applyPresetMenuItem(_:)),
                    keyEquivalent: ""
                )
                presetItem.target = self
                presetItem.representedObject = preset.id.uuidString
                presetsMenu.addItem(presetItem)
            }
        }
        presetsMenu.addItem(.separator())
        let saveCurrentItem = NSMenuItem(
            title: "保存当前布局为预设…",
            action: #selector(promptSaveCurrentPreset),
            keyEquivalent: ""
        )
        saveCurrentItem.target = self
        presetsMenu.addItem(saveCurrentItem)

        let presetsParent = NSMenuItem(title: "切换布局预设", action: nil, keyEquivalent: "")
        presetsParent.submenu = presetsMenu
        menu.addItem(presetsParent)

        let openEditorItem = NSMenuItem(
            title: "命名、布局与关闭规则设置…",
            action: #selector(openLayoutEditor),
            keyEquivalent: ","
        )
        openEditorItem.target = self
        menu.addItem(openEditorItem)

        menu.addItem(.separator())

        let externals = displays.filter { !$0.isBuiltin }
        let hasActiveExternal = externals.contains(where: \.isActive)
        let hasAnyDisabled = displays.contains { !$0.isActive || $0.disabledByApp }

        let disableAllExtItem = NSMenuItem(
            title: "停用全部外接显示器",
            action: #selector(disableAllExternalDisplays),
            keyEquivalent: ""
        )
        disableAllExtItem.target = self
        disableAllExtItem.isEnabled = hasActiveExternal
        menu.addItem(disableAllExtItem)

        let enableAllItem = NSMenuItem(
            title: "恢复全部已停用显示器",
            action: #selector(enableAllDisplays),
            keyEquivalent: ""
        )
        enableAllItem.target = self
        enableAllItem.isEnabled = hasAnyDisabled
        menu.addItem(enableAllItem)

        let refreshItem = NSMenuItem(
            title: "刷新显示器列表",
            action: #selector(manualRefresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(
            title: "开机自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        let autoRestoreItem = NSMenuItem(
            title: "退出时自动恢复所有已停用显示器",
            action: #selector(toggleAutoRestore),
            keyEquivalent: ""
        )
        autoRestoreItem.target = self
        autoRestoreItem.state = autoRestoreOnQuit ? .on : .off
        menu.addItem(autoRestoreItem)

        let quitItem = NSMenuItem(
            title: "退出 MonitorBlock",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func toggleSingleDisplay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let displayID = CGDirectDisplayID(number.uint32Value)
        do {
            try manager.toggleDisplay(id: displayID)
            scheduleRefresh(delay: 0.25)
        } catch {
            showError(error)
        }
    }

    @objc private func identifyAllDisplays() {
        let displays = manager.listDisplays(includeBuiltin: true)
        DisplayIdentifierOverlay.shared.identify(displays: displays)
    }

    @objc private func applyPresetMenuItem(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let presetID = UUID(uuidString: uuidString) else { return }
        do {
            try manager.applyPreset(id: presetID)
            scheduleRefresh(delay: 0.25)
        } catch {
            showError(error)
        }
    }

    @objc private func promptSaveCurrentPreset() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "保存当前显示器布局"
        alert.informativeText = "为当前的多屏相对位置和主屏设置命名："
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "例如：办公三屏 / 便携双屏"
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            manager.savePreset(name: input.stringValue)
            refreshUI()
        }
    }

    @objc private func openLayoutEditor() {
        if layoutEditorController == nil {
            layoutEditorController = LayoutEditorWindowController(manager: manager) { [weak self] in
                self?.scheduleRefresh(delay: 0.2)
            }
        }
        layoutEditorController?.showAndRefresh()
    }

    @objc private func disableAllExternalDisplays() {
        do {
            try manager.disableAllExternal()
            scheduleRefresh(delay: 0.25)
        } catch {
            showError(error)
        }
    }

    @objc private func enableAllDisplays() {
        do {
            try manager.enableAllDisplays()
            scheduleRefresh(delay: 0.25)
        } catch {
            showError(error)
        }
    }

    @objc private func manualRefresh() {
        refreshUI()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            refreshUI()
        } catch {
            showError(error)
        }
    }

    @objc private func toggleAutoRestore() {
        autoRestoreOnQuit.toggle()
        refreshUI()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作未能完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
        refreshUI()
    }
}
