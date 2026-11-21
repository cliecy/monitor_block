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
    private var popoverViewModel: MenuBarPopoverViewModel!
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
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popoverViewModel = MenuBarPopoverViewModel(
            displayManager: displayManager,
            audioManager: audioManager,
            launchAtLogin: launchAtLogin,
            autoRestoreOnQuit: autoRestoreOnQuit,
            onOpenLayoutEditor: { [weak self] in
                self?.popover.performClose(nil)
                self?.openLayoutEditor()
            },
            onPromptSavePreset: { [weak self] in
                self?.popover.performClose(nil)
                self?.promptSaveCurrentPreset()
            },
            onToggleAutoRestore: { [weak self] in
                guard let self else { return }
                self.autoRestoreOnQuit.toggle()
                self.popoverViewModel.refresh(readHardwareDDC: false, autoRestoreValue: self.autoRestoreOnQuit)
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
            rootView: MenuBarPopoverView(viewModel: popoverViewModel)
        )

        updateStatusIcon()

        displayManager.startObservingReconfiguration { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh(checkSafetyFallback: true)
            }
        }

        audioManager.startObservingChanges { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh(delay: 0.15, checkSafetyFallback: false)
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
        displayManager.stopObservingReconfiguration()
        audioManager.stopObservingChanges()
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
            popoverViewModel.refresh(readHardwareDDC: true, autoRestoreValue: autoRestoreOnQuit)
            updateStatusIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Refresh

    private func scheduleRefresh(delay: TimeInterval = 0.25, checkSafetyFallback: Bool = false) {
        pendingRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if checkSafetyFallback {
                self.displayManager.ensureBuiltinActiveIfNoExternalActive()
            }
            self.updateStatusIcon()
            if self.popover.isShown {
                self.popoverViewModel.refresh(readHardwareDDC: false, autoRestoreValue: self.autoRestoreOnQuit)
            }
        }
        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let displays = displayManager.listDisplays(includeBuiltin: true)
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

    // MARK: - Secondary Windows & Prompts

    private func openLayoutEditor() {
        if layoutEditorController == nil {
            layoutEditorController = LayoutEditorWindowController(manager: displayManager) { [weak self] in
                self?.scheduleRefresh(delay: 0.2, checkSafetyFallback: false)
            }
        }
        layoutEditorController?.showAndRefresh()
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
            popoverViewModel.refresh(readHardwareDDC: false)
        }
    }
}
