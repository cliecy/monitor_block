import AppKit
import MonitorBlockCore
import SwiftUI

@MainActor
final class MainAppWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: AppViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        let rootView = MainAppRootView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MonitorBlock"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 780, height: 540)
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate(section: AppViewModel.MainWindowSection? = nil) {
        if let section {
            viewModel.mainSection = section
        }
        viewModel.refresh(readHardwareDDC: true)

        // 主窗口打开时临时切换为常规 App 态，支持 Command+Tab 切换与原生窗口体验
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭主窗口后自动退回菜单栏常驻模式，不退出应用
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Full Desktop App Root View (Sidebar + Detail)

struct MainAppRootView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 214)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            detailArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 留出红绿灯窗口按钮空间
            Spacer().frame(height: 18)

            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .cornerRadius(7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("MonitorBlock")
                        .font(.system(size: 15, weight: .bold))
                    Text("多屏与音频控制中心")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)

            VStack(spacing: 4) {
                ForEach(AppViewModel.MainWindowSection.allCases) { section in
                    let isSelected = (viewModel.mainSection == section)
                    Button {
                        viewModel.mainSection = section
                        if section == .disableRules {
                            viewModel.loadRuleForSelectedTarget()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbolName)
                                .font(.system(size: 13.5, weight: .medium))
                                .frame(width: 20)
                            Text(section.rawValue)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(isSelected ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("菜单栏与主窗口实时同步")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Text("关闭此窗口仍会在菜单栏常驻")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Detail Container

    private var detailArea: some View {
        VStack(spacing: 0) {
            // Top Toolbar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.mainSection.rawValue)
                        .font(.system(size: 18, weight: .bold))
                    Text(subtitleForCurrentSection)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    viewModel.identifyDisplays()
                } label: {
                    Label("识别所有屏幕", systemImage: "sparkles.tv")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    viewModel.refresh(readHardwareDDC: true)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if let banner = viewModel.statusBanner {
                StatusBannerView(
                    text: banner.text,
                    isError: banner.isError,
                    onDismiss: { viewModel.clearBanner() }
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
            }

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    switch viewModel.mainSection {
                    case .displays:
                        displaysDetailView
                    case .arrangement:
                        arrangementDetailView
                    case .disableRules:
                        disableRulesDetailView
                    case .audio:
                        audioDetailView
                    case .settings:
                        settingsDetailView
                    }
                }
                .padding(22)
            }
        }
    }

    private var subtitleForCurrentSection: String {
        switch viewModel.mainSection {
        case .displays:
            return "独立控制每台显示器的开关、主屏幕 / 拓展 / 镜像模式、输入源与自定义命名"
        case .arrangement:
            return "拖拽排布多屏相对坐标与主屏位置，保存并一键切换命名布局预设"
        case .disableRules:
            return "为任意屏幕定制“关闭它之后剩余屏幕的排布与主屏”，重新开启时自动恢复"
        case .audio:
            return "切换系统音频输出设备，统一调节系统音量与外接屏 DDC/CI 硬件音量"
        case .settings:
            return "开机自启动、退出安全恢复策略与 DDC/CI 输入源协议偏好"
        }
    }

    // MARK: - Section 1: Displays Management

    private var displaysDetailView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if viewModel.hasActiveExternal {
                    Button {
                        viewModel.disableAllExternal()
                    } label: {
                        Label("停用全部外接屏", systemImage: "moon.zzz")
                    }
                    .buttonStyle(.bordered)
                }
                if viewModel.hasAnyMirroredDisplay {
                    Button {
                        viewModel.stopAllMirroring()
                    } label: {
                        Label("取消全部镜像", systemImage: "rectangle.split.2x1")
                    }
                    .buttonStyle(.bordered)
                }
                if viewModel.hasAnyDisabledDisplay {
                    Button {
                        viewModel.enableAllDisplays()
                    } label: {
                        Label("恢复全部屏幕", systemImage: "sun.max")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }

            if viewModel.displays.isEmpty {
                SurfaceCard {
                    Text("当前未检测到显示器。")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.displays) { display in
                        DisplayControlCard(
                            display: display,
                            showInlineRename: true,
                            viewModel: viewModel
                        )
                    }
                }
            }
        }
    }

    // MARK: - Section 2: Arrangement & Presets

    private var arrangementDetailView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    DisplayArrangementCanvas(
                        placements: $viewModel.livePlacements,
                        selectedUUID: $viewModel.selectedLiveUUID,
                        dragSession: viewModel.liveDragSession
                    )

                    arrangementToolbar(
                        selectedUUID: viewModel.selectedLiveUUID,
                        placements: viewModel.livePlacements,
                        inLive: true
                    )

                    Divider()

                    HStack(spacing: 10) {
                        Button("恢复当前实际位置") {
                            viewModel.refresh(readHardwareDDC: false)
                        }
                        Button("应用此布局") {
                            viewModel.applyLiveLayout()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.livePlacements.isEmpty)

                        Spacer()

                        TextField("输入预设名（如：办公三屏）", text: $viewModel.newPresetName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)

                        Button("保存为预设") {
                            viewModel.saveCurrentAsPreset()
                        }
                        .disabled(viewModel.livePlacements.isEmpty)
                    }
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("已保存的布局预设")
                        .font(.system(size: 13.5, weight: .semibold))

                    if viewModel.presets.isEmpty {
                        Text("暂无布局预设。在上方拖拽排好屏幕位置后输入名称并点击「保存为预设」，即可在菜单栏和主窗口一键切换。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(viewModel.presets) { preset in
                                HStack(spacing: 8) {
                                    Button {
                                        viewModel.applyPreset(preset)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(preset.name)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .lineLimit(1)
                                            Text("\(preset.placements.count) 块屏幕")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        viewModel.deletePreset(preset)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除此预设")
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section 3: Disable Rules

    private var disableRulesDetailView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.displays.count <= 1 {
                SurfaceCard {
                    Text("至少需要连接 2 块显示器才能配置「关闭某屏后的剩余布局规则」。")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            } else {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Text("当关闭此屏幕时：")
                                .font(.system(size: 13, weight: .medium))

                            Picker(
                                "",
                                selection: Binding(
                                    get: { viewModel.selectedRuleTargetUUID ?? "" },
                                    set: { viewModel.selectRuleTarget(uuid: $0) }
                                )
                            ) {
                                ForEach(viewModel.displays) { display in
                                    let builtinTag = display.isBuiltin ? " [内置]" : ""
                                    let badge = viewModel.savedRuleUUIDs.contains(display.uuid) ? "（已配置）" : ""
                                    Text("\(display.name)\(builtinTag)\(badge)").tag(display.uuid)
                                }
                            }
                            .frame(width: 280)

                            Spacer()

                            Button("捕获当前剩余屏幕布局") {
                                viewModel.captureCurrentIntoRule()
                            }
                        }

                        if viewModel.rulePlacements.isEmpty {
                            Text("关闭该屏幕后没有剩余屏幕可排布。")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            DisplayArrangementCanvas(
                                placements: $viewModel.rulePlacements,
                                selectedUUID: $viewModel.selectedRuleItemUUID,
                                dragSession: viewModel.ruleDragSession
                            )

                            arrangementToolbar(
                                selectedUUID: viewModel.selectedRuleItemUUID,
                                placements: viewModel.rulePlacements,
                                inLive: false
                            )
                        }

                        Divider()

                        HStack {
                            Toggle("重新开启该屏幕时，自动恢复关闭前的原布局", isOn: $viewModel.restorePreviousOnEnable)

                            Spacer()

                            if let targetUUID = viewModel.selectedRuleTargetUUID,
                               viewModel.savedRuleUUIDs.contains(targetUUID) {
                                Button("清除规则", role: .destructive) {
                                    viewModel.deleteRuleForSelectedTarget()
                                }
                            }

                            Button("保存规则") {
                                viewModel.saveRuleForSelectedTarget()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.rulePlacements.isEmpty)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section 4: Audio & DDC Volume

    private var audioDetailView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前默认输出主音量")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.mainTargetDisplayTitle())
                                .font(.system(size: 16, weight: .bold))
                        }
                        Spacer()
                        if let badge = viewModel.volumeMode.badgeText {
                            let color: Color = {
                                switch viewModel.volumeMode {
                                case .coreAudio: return .blue
                                case .ddc: return .teal
                                case .unsupported: return .secondary
                                }
                            }()
                            PillTag(text: badge, color: color)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            viewModel.toggleMainMute()
                        } label: {
                            Image(systemName: volumeSymbolName(level: viewModel.volume, muted: viewModel.isMuted))
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(viewModel.isMuted ? .secondary : .accentColor)
                                .frame(width: 34, height: 34)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.volumeMode == .unsupported)

                        Slider(
                            value: Binding(
                                get: { viewModel.isMuted ? 0 : viewModel.volume },
                                set: { viewModel.updateMainVolume($0) }
                            ),
                            in: 0...1
                        )
                        .disabled(viewModel.volumeMode == .unsupported)

                        Text(viewModel.volumeMode == .unsupported ? "--" : "\(Int((viewModel.isMuted ? 0 : viewModel.volume * 100).rounded()))%")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("音频输出设备")
                            .font(.system(size: 13.5, weight: .semibold))
                        if viewModel.audioDevices.isEmpty {
                            Text("未检测到音频输出设备")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 5) {
                                ForEach(viewModel.audioDevices) { device in
                                    Button {
                                        viewModel.selectAudioOutput(device)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: device.transport.symbolName)
                                                .font(.system(size: 13))
                                                .foregroundColor(device.isDefault ? .white : .secondary)
                                                .frame(width: 28, height: 28)
                                                .background(device.isDefault ? Color.accentColor : Color.primary.opacity(0.08))
                                                .clipShape(Circle())
                                            Text(viewModel.displayTitle(for: device))
                                                .font(.system(size: 12.5, weight: device.isDefault ? .semibold : .regular))
                                                .lineLimit(1)
                                            Spacer()
                                            if device.isDefault {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.accentColor)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(device.isDefault ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
                                        .cornerRadius(8)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("外接显示器独立音量（DDC/CI）")
                            .font(.system(size: 13.5, weight: .semibold))
                        if viewModel.ddcEndpoints.isEmpty {
                            Text("当前未检测到支持 DDC/CI 的外接显示器。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(viewModel.ddcEndpoints) { ep in
                                    let epVol = viewModel.ddcVolumes[ep.index] ?? 0.5
                                    let epMuted = viewModel.ddcMuted[ep.index] ?? false
                                    let isLinked = (viewModel.activeDDCEndpointIndex == ep.index)

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(viewModel.displayTitle(for: ep))
                                                .font(.system(size: 12.5, weight: .semibold))
                                            Spacer()
                                            if viewModel.activeDDCEndpointIndex != nil {
                                                Button(isLinked ? "已联动主音量" : "联动为主音量") {
                                                    viewModel.bindActiveAudioToDDC(endpointIndex: ep.index)
                                                }
                                                .font(.caption2)
                                                .buttonStyle(.bordered)
                                                .tint(isLinked ? .teal : .secondary)
                                                .controlSize(.mini)
                                            }
                                        }
                                        HStack(spacing: 8) {
                                            Button {
                                                viewModel.toggleDDCMute(endpointIndex: ep.index)
                                            } label: {
                                                Image(systemName: volumeSymbolName(level: epVol, muted: epMuted))
                                                    .foregroundColor(epMuted ? .secondary : .teal)
                                                    .frame(width: 24, height: 24)
                                            }
                                            .buttonStyle(.plain)

                                            Slider(
                                                value: Binding(
                                                    get: { epMuted ? 0 : epVol },
                                                    set: { viewModel.updateDDCVolume(endpointIndex: ep.index, value: $0) }
                                                ),
                                                in: 0...1
                                            )

                                            Text("\(Int((epMuted ? 0 : epVol * 100).rounded()))%")
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .frame(width: 36, alignment: .trailing)
                                        }
                                    }
                                    .padding(10)
                                    .background(Color.primary.opacity(0.035))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Section 5: General Settings

    private var settingsDetailView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("启动与安全恢复")
                        .font(.system(size: 13.5, weight: .semibold))

                    Toggle(
                        "登录 macOS 时自动启动 MonitorBlock",
                        isOn: Binding(
                            get: { viewModel.launchAtLoginEnabled },
                            set: { _ in viewModel.toggleLaunchAtLogin() }
                        )
                    )

                    Toggle(
                        "退出 MonitorBlock 时自动恢复所有已停用的显示器",
                        isOn: Binding(
                            get: { viewModel.autoRestoreOnQuit },
                            set: { _ in viewModel.toggleAutoRestore() }
                        )
                    )
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("DDC/CI 视频输入源默认协议")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("默认「自动」会自动兼容标准 MCCS (0x60) 与 LG 专有通道 (0x50/0xF4)。如遇特殊型号可手动切换，或直接在显示器卡片中点击 ⚙︎ 校准具体端口。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker(
                        "协议模式",
                        selection: Binding(
                            get: { viewModel.inputProtocolMode },
                            set: { viewModel.setInputProtocolMode($0) }
                        )
                    ) {
                        ForEach(InputSourceProtocolMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                }
            }

            SurfaceCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("安全机制说明")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("所有显示启停、镜像与排布操作均使用 kCGConfigureForSession（仅当前会话生效），不会污染系统 plist。若出现异常，重新插拔线缆或重启系统即可立即恢复。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("退出 MonitorBlock", role: .destructive) {
                        viewModel.quitApp()
                    }
                }
            }
        }
    }

    // MARK: - Shared Arrangement Toolbar

    @ViewBuilder
    private func arrangementToolbar(
        selectedUUID: String?,
        placements: [DisplayPlacement],
        inLive: Bool
    ) -> some View {
        let selected = placements.first(where: { $0.uuid == selectedUUID })
        HStack(spacing: 8) {
            if let selected {
                Text("已选中：\(selected.name)  坐标 (\(selected.x), \(selected.y))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("设为主屏幕") {
                    viewModel.markPlacementAsMain(uuid: selected.uuid, inLive: inLive)
                }
                .disabled(selected.isMain)

                if placements.count > 1 {
                    Button("靠左") { viewModel.placeSelected(.left, inLive: inLive) }
                    Button("靠右") { viewModel.placeSelected(.right, inLive: inLive) }
                    Button("靠上") { viewModel.placeSelected(.top, inLive: inLive) }
                    Button("靠下") { viewModel.placeSelected(.bottom, inLive: inLive) }
                }
            } else {
                Text("点击或拖拽画布中的显示器调整位置（松手自动吸附贴边）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}
