import AppKit
import CoreGraphics
import Foundation
import MonitorBlockCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let autoRestoreKey = "MonitorBlock.autoRestoreOnQuit"

    private let displayManager = DisplayManager()
    private let audioManager = AudioManager()
    private let launchAtLogin = LaunchAtLoginManager()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var appViewModel: AppViewModel!
    private var mainWindowController: MainAppWindowController?
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
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        appViewModel = AppViewModel(
            displayManager: displayManager,
            audioManager: audioManager,
            launchAtLogin: launchAtLogin,
            autoRestoreOnQuit: autoRestoreOnQuit,
            onOpenMainWindow: { [weak self] section in
                self?.popover.performClose(nil)
                self?.openMainWindow(section: section)
            },
            onPromptSavePreset: { [weak self] in
                self?.popover.performClose(nil)
                self?.promptSaveCurrentPreset()
            },
            onToggleAutoRestore: { [weak self] in
                guard let self else { return }
                self.autoRestoreOnQuit.toggle()
                self.appViewModel.refresh(readHardwareDDC: false, autoRestoreValue: self.autoRestoreOnQuit)
            },
            onQuit: {
                NSApp.terminate(nil)
            },
            onStatusChanged: { [weak self] in
                self?.updateStatusIcon()
            }
        )

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(viewModel: appViewModel)
        )

        updateStatusIcon()

        // 启动后后台静默探测一次外接屏硬件能力与输入源，无需等首次点开菜单栏才识别
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.appViewModel.probeDDCStateAsync()
        }

        displayManager.startObservingReconfiguration { [weak self] in
            Task { @MainActor in
                // 留足 1.1s 等待 HDMI / HDCP / 转接头链路握手完成后再探测 DDC，防止过早读写触发 0xE0114000
                self?.scheduleRefresh(delay: 1.1, checkSafetyFallback: true, reprobeDDC: true)
            }
        }

        audioManager.startObservingChanges { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh(delay: 0.15, checkSafetyFallback: false, reprobeDDC: false)
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh(delay: 1.3, checkSafetyFallback: true, reprobeDDC: true)
            }
        }
    }

    /// 当应用已在菜单栏常驻时，用户再次从 Finder / Spotlight 打开 MonitorBlock.app 直接唤出独立桌面主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow(section: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayManager.stopObservingReconfiguration()
        audioManager.stopObservingChanges()
        audioManager.stopSoftwareVolume()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if autoRestoreOnQuit {
            _ = try? displayManager.enableAllDisplays()
        }
    }

    // MARK: - Popover Toggle

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            appViewModel.refresh(readHardwareDDC: true, autoRestoreValue: autoRestoreOnQuit)
            updateStatusIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Refresh

    private func scheduleRefresh(
        delay: TimeInterval = 0.25,
        checkSafetyFallback: Bool = false,
        reprobeDDC: Bool = false
    ) {
        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if checkSafetyFallback {
                self.displayManager.ensureBuiltinActiveIfNoExternalActive()
            }
            let latestDisplays = self.displayManager.listDisplays(includeBuiltin: true)
            self.audioManager.updateKnownDisplays(latestDisplays)
            self.updateStatusIcon()

            let isMainWindowVisible = self.mainWindowController?.window?.isVisible ?? false
            if self.popover.isShown || isMainWindowVisible || reprobeDDC {
                self.appViewModel.refresh(readHardwareDDC: reprobeDDC, autoRestoreValue: self.autoRestoreOnQuit)
            } else {
                // 即使面板未打开，系统默认输出设备切换时也需立刻释放不再适用的软件音量代理
                _ = self.audioManager.currentVolumeSnapshot(readHardwareDDC: false, activateSoftwareVolumeIfNeeded: false)
            }
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let displays = displayManager.listDisplays(includeBuiltin: true)
        let externals = displays.filter { !$0.isBuiltin }
        let enabledCount = displays.filter(\.isEnabledForDisplay).count
        let mirroredCount = displays.filter { $0.usageMode.isMirrored }.count

        let symbolName: String
        let tooltip: String

        if externals.isEmpty {
            symbolName = "laptopcomputer"
            tooltip = "MonitorBlock：仅内置显示器"
        } else if mirroredCount > 0 {
            symbolName = "rectangle.on.rectangle"
            tooltip = "MonitorBlock：多屏镜像中（\(enabledCount) 块活跃）"
        } else if enabledCount > 1 {
            symbolName = "display.2"
            tooltip = "MonitorBlock：多屏拓展中（\(enabledCount) 块活跃）"
        } else if externals.contains(where: \.isEnabledForDisplay) {
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

    // MARK: - Main Desktop Window & Prompts

    private func openMainWindow(section: AppViewModel.MainWindowSection?) {
        if mainWindowController == nil {
            mainWindowController = MainAppWindowController(viewModel: appViewModel)
        }
        mainWindowController?.showAndActivate(section: section)
    }

    private func promptSaveCurrentPreset() {
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
            displayManager.savePreset(name: input.stringValue)
            appViewModel.refresh(readHardwareDDC: false)
        }
    }
}
