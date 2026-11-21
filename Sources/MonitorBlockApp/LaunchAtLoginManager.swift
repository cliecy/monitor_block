import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager {
    private let agentLabel = "local.cliecy.MonitorBlock"

    private var launchAgentURL: URL {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return libraryDir
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // 优先使用 macOS 13+ 原生登录项 API
            if Bundle.main.bundleURL.pathExtension == "app" {
                do {
                    try SMAppService.mainApp.register()
                    removeLaunchAgentPlistIfNeeded()
                    return
                } catch {
                    // 本地自编译未公证应用可能无法通过 SMAppService 注册，自动回退到用户级 LaunchAgent
                }
            }
            try writeLaunchAgentPlist()
        } else {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try? SMAppService.mainApp.unregister()
            }
            removeLaunchAgentPlistIfNeeded()
        }
    }

    private func writeLaunchAgentPlist() throws {
        let dir = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let programArguments: [String]
        if Bundle.main.bundleURL.pathExtension == "app" {
            programArguments = ["/usr/bin/open", "-a", Bundle.main.bundleURL.path]
        } else if let executablePath = Bundle.main.executablePath {
            programArguments = [executablePath]
        } else {
            throw NSError(
                domain: "MonitorBlock.LaunchAtLogin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法定位当前应用程序路径。"]
            )
        }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func removeLaunchAgentPlistIfNeeded() {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
    }
}
