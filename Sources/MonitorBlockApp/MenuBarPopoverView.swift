import AppKit
import MonitorBlockCore
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
            headerBar

            Picker("", selection: $viewModel.popoverTab) {
                ForEach(AppViewModel.PopoverTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let banner = viewModel.statusBanner {
                StatusBannerView(
                    text: banner.text,
                    isError: banner.isError,
                    onDismiss: { viewModel.clearBanner() }
                )
            }

            if !viewModel.isPrivateAPIAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                    Text("当前系统不支持软断开 API，仅支持主屏/镜像/布局/输入源与音频控制。")
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    switch viewModel.popoverTab {
                    case .displays:
                        displaysTabContent
                    case .audio:
                        audioTabContent
                    case .layout:
                        layoutTabContent
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(minHeight: 280, maxHeight: 460)

            Divider()

            footerBar
        }
        .padding(14)
        .frame(width: 404)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.75))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .cornerRadius(5)
            }
            Text("MonitorBlock")
                .font(.system(size: 14.5, weight: .semibold))

            Spacer()

            headerIconButton(symbol: "sparkles.tv", help: "识别所有显示器（屏幕闪显名称）") {
                viewModel.identifyDisplays()
            }
            headerIconButton(symbol: "arrow.clockwise", help: "刷新显示器、输入源与音频状态") {
                viewModel.refresh(readHardwareDDC: true)
            }

            Button {
                viewModel.openMainWindow(section: mappedSectionForCurrentTab)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("主窗口")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.accentColor.opacity(0.14))
                .foregroundColor(.accentColor)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("打开完整桌面主窗口（侧边栏大界面）")
        }
    }

    private var mappedSectionForCurrentTab: AppViewModel.MainWindowSection {
        switch viewModel.popoverTab {
        case .displays: return .displays
        case .audio: return .audio
        case .layout: return .arrangement
        }
    }

    private func headerIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Tab 1: Displays

    private var displaysTabContent: some View {
        VStack(spacing: 9) {
            if viewModel.displays.isEmpty {
                SurfaceCard {
                    HStack {
                        Spacer()
                        Text("未检测到显示器")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                }
            } else {
                ForEach(viewModel.displays) { display in
                    DisplayControlCard(
                        display: display,
                        showInlineRename: false,
                        viewModel: viewModel
                    )
                }
            }

            // 底部快捷动作条
            if viewModel.hasActiveExternal || viewModel.hasAnyDisabledDisplay || viewModel.hasAnyMirroredDisplay {
                HStack(spacing: 6) {
                    if viewModel.hasActiveExternal {
                        Button("停用全部外接") {
                            viewModel.disableAllExternal()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if viewModel.hasAnyMirroredDisplay {
                        Button("取消全部镜像") {
                            viewModel.stopAllMirroring()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    if viewModel.hasAnyDisabledDisplay {
                        Button("恢复全部屏幕") {
                            viewModel.enableAllDisplays()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Tab 2: Audio

    private var audioTabContent: some View {
        VStack(spacing: 10) {
            // 当前主音量卡片
            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("主音量")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(viewModel.mainTargetDisplayTitle())
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        Spacer()
                        if let badge = viewModel.volumeMode.badgeText {
                            PillTag(text: badge, color: volumeModeBadgeColor)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            viewModel.toggleMainMute()
                        } label: {
                            Image(systemName: volumeSymbolName(level: viewModel.volume, muted: viewModel.isMuted))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(viewModel.isMuted ? .secondary : .accentColor)
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(7)
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
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            // 音频输出设备选择
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("音频输出设备")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)

                    if viewModel.audioDevices.isEmpty {
                        Text("未检测到音频输出设备")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(viewModel.audioDevices) { device in
                                audioDeviceRow(device)
                            }
                        }
                    }
                }
            }

            // 外接显示器独立 DDC 硬件音量
            if !viewModel.ddcEndpoints.isEmpty {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("外接显示器硬件音量（DDC/CI）")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        VStack(spacing: 8) {
                            ForEach(viewModel.ddcEndpoints) { ep in
                                ddcVolumeRow(ep)
                            }
                        }
                    }
                }
            }
        }
    }

    private func audioDeviceRow(_ device: AudioOutputDevice) -> some View {
        Button {
            viewModel.selectAudioOutput(device)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.transport.symbolName)
                    .font(.system(size: 12.5))
                    .foregroundColor(device.isDefault ? .white : .secondary)
                    .frame(width: 26, height: 26)
                    .background(device.isDefault ? Color.accentColor : Color.primary.opacity(0.08))
                    .clipShape(Circle())

                Text(viewModel.displayTitle(for: device))
                    .font(.system(size: 12.5, weight: device.isDefault ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if device.isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(device.isDefault ? Color.accentColor.opacity(0.12) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ddcVolumeRow(_ ep: DDCDisplayEndpoint) -> some View {
        let epVol = viewModel.ddcVolumes[ep.index] ?? 0.5
        let epMuted = viewModel.ddcMuted[ep.index] ?? false
        let isLinkedToMain = (viewModel.activeDDCEndpointIndex == ep.index)

        return HStack(spacing: 8) {
            Button {
                viewModel.toggleDDCMute(endpointIndex: ep.index)
            } label: {
                Image(systemName: volumeSymbolName(level: epVol, muted: epMuted))
                    .font(.system(size: 13))
                    .foregroundColor(epMuted ? .secondary : .teal)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Text(viewModel.displayTitle(for: ep))
                .font(.system(size: 11.5, weight: isLinkedToMain ? .semibold : .regular))
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)

            Slider(
                value: Binding(
                    get: { epMuted ? 0 : epVol },
                    set: { viewModel.updateDDCVolume(endpointIndex: ep.index, value: $0) }
                ),
                in: 0...1
            )

            Text("\(Int((epMuted ? 0 : epVol * 100).rounded()))%")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .trailing)

            if viewModel.activeDDCEndpointIndex != nil {
                Button(isLinkedToMain ? "已联动" : "联动") {
                    viewModel.bindActiveAudioToDDC(endpointIndex: ep.index)
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.bordered)
                .tint(isLinkedToMain ? .teal : .secondary)
                .controlSize(.mini)
            }
        }
    }

    private var volumeModeBadgeColor: Color {
        switch viewModel.volumeMode {
        case .coreAudio: return .blue
        case .ddc: return .teal
        case .unsupported: return .secondary
        }
    }

    // MARK: - Tab 3: Layout

    private var layoutTabContent: some View {
        VStack(spacing: 10) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("当前多屏拓扑")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("在主窗口中拖拽调整") {
                            viewModel.openMainWindow(section: .arrangement)
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }

                    MiniLayoutPreviewView(
                        placements: viewModel.livePlacements,
                        mirroredDisplays: viewModel.displays.filter { $0.usageMode.isMirrored }
                    )
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("布局预设")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("+ 保存当前布局") {
                            viewModel.promptSavePreset()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if viewModel.presets.isEmpty {
                        Text("暂无已保存的预设。点击右上角「保存当前布局」即可一键快速切换。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(viewModel.presets) { preset in
                                Button {
                                    viewModel.applyPreset(preset)
                                } label: {
                                    HStack {
                                        Image(systemName: "rectangle.3.group")
                                            .font(.caption)
                                        Text(preset.name)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.055))
                                    .cornerRadius(7)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            SurfaceCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("关闭后自动布局规则")
                            .font(.system(size: 12, weight: .semibold))
                        Text("已配置 \(viewModel.savedRuleUUIDs.count) 条规则 · 可设定关闭任意屏幕后剩余屏幕的新布局")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("管理规则") {
                        viewModel.openMainWindow(section: .disableRules)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            Toggle(
                "开机自启",
                isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { _ in viewModel.toggleLaunchAtLogin() }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)

            Toggle(
                "退出恢复",
                isOn: Binding(
                    get: { viewModel.autoRestoreOnQuit },
                    set: { _ in viewModel.toggleAutoRestore() }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)

            Spacer()

            Button("退出") {
                viewModel.quitApp()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }
}
