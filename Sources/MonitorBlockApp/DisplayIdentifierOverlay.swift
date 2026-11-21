import AppKit
import CoreGraphics
import MonitorBlockCore
import SwiftUI

/// 在每块活跃显示器正中央弹出大号半透明识别浮层，帮助区分同型号显示器
@MainActor
final class DisplayIdentifierOverlay {
    static let shared = DisplayIdentifierOverlay()

    private var windows: [NSWindow] = []
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func identify(displays: [DisplayInfo], onlyUUID: String? = nil, duration: TimeInterval = 2.4) {
        dismissImmediately()

        let infoByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let key = NSDeviceDescriptionKey("NSScreenNumber")

        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[key] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(num.uint32Value)
            guard let info = infoByID[displayID] else { continue }
            if let onlyUUID, info.uuid != onlyUUID {
                continue
            }

            let panelWidth: CGFloat = 460
            let panelHeight: CGFloat = 170
            let frame = screen.visibleFrame
            let rect = NSRect(
                x: frame.midX - panelWidth / 2,
                y: frame.midY - panelHeight / 2,
                width: panelWidth,
                height: panelHeight
            )

            let window = NSWindow(
                contentRect: rect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .statusBar
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: IdentifyBadgeView(display: info))
            window.orderFrontRegardless()
            windows.append(window)
        }

        guard !windows.isEmpty else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOutAndDismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func fadeOutAndDismiss() {
        let current = windows
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            for win in current {
                win.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                for win in current {
                    win.orderOut(nil)
                }
                self?.windows.removeAll { current.contains($0) }
            }
        })
    }

    private func dismissImmediately() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        for win in windows {
            win.orderOut(nil)
        }
        windows.removeAll()
    }
}

private struct IdentifyBadgeView: View {
    let display: DisplayInfo

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 26, weight: .semibold))
                Text(display.name)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            HStack(spacing: 10) {
                if let res = display.resolutionText {
                    Text(res)
                }
                if display.isMain {
                    Text("主屏")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.85))
                        .cornerRadius(4)
                }
                if display.isBuiltin {
                    Text("内置")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.9))

            if display.customName != nil {
                Text("系统原名：\(display.systemName)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                )
        )
    }
}
