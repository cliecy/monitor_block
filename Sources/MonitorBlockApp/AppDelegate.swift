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
                self?.scheduleRefresh()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh(delay: 0.6)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopObservingReconfiguration()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if autoRestoreOnQuit {
            _ = try? manager.enableAllExternal()
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    // MARK: - UI Refresh

    private func scheduleRefresh(delay: TimeInterval = 0.25) {
        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshUI()
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshUI() {
        let externals = manager.listDisplays(includeBuiltin: false)
        updateStatusIcon(externals: externals)
        rebuildMenu(externals: externals)
    }

    private func updateStatusIcon(externals: [DisplayInfo]) {
        guard let button = statusItem.button else { return }
        let symbolName: String
        let tooltip: String

        if externals.isEmpty {
            symbolName = "display"
            tooltip = "MonitorBlock：未检测到外接显示器"
        } else if externals.contains(where: \.isActive) {
            symbolName = "display.2"
            tooltip = "MonitorBlock：外接显示器使用中"
        } else {
            symbolName = "laptopcomputer"
            tooltip = "MonitorBlock：外接显示器已停用"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MonitorBlock")
        image?.isTemplate = true
        button.image = image
        button.toolTip = tooltip
    }

    private func rebuildMenu(externals: [DisplayInfo]) {
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

        let header = NSMenuItem(title: "外接显示器", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if externals.isEmpty {
            let emptyItem = NSMenuItem(title: "  未检测到外接显示器", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for display in externals {
                var title = display.name
                if let res = display.resolutionText {
                    title += "  (\(res))"
                }
                if !display.isActive {
                    title += " [已停用]"
                } else if manager.disableRule(forDisplayUUID: display.uuid) != nil {
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
            title: "布局与关闭规则设置…",
            action: #selector(openLayoutEditor),
            keyEquivalent: ","
        )
        openEditorItem.target = self
        menu.addItem(openEditorItem)

        menu.addItem(.separator())

        let hasActiveExternal = externals.contains(where: \.isActive)
        let hasDisabledExternal = externals.contains { !$0.isActive || $0.disabledByApp }

        let disableAllItem = NSMenuItem(
            title: "全部停用外接显示器",
            action: #selector(disableAllExternalDisplays),
            keyEquivalent: ""
        )
        disableAllItem.target = self
        disableAllItem.isEnabled = hasActiveExternal
        menu.addItem(disableAllItem)

        let enableAllItem = NSMenuItem(
            title: "全部恢复外接显示器",
            action: #selector(enableAllExternalDisplays),
            keyEquivalent: ""
        )
        enableAllItem.target = self
        enableAllItem.isEnabled = hasDisabledExternal
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
            title: "退出时自动恢复外接显示器",
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
            try manager.toggleExternal(id: displayID)
            scheduleRefresh(delay: 0.25)
        } catch {
            showError(error)
        }
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

    @objc private func enableAllExternalDisplays() {
        do {
            try manager.enableAllExternal()
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
