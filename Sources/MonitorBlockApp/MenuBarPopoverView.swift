import AppKit
import CoreGraphics
import MonitorBlockCore
import SwiftUI

@MainActor
final class MenuBarPopoverViewModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var presets: [LayoutPreset] = []
    @Published var audioDevices: [AudioOutputDevice] = []
    @Published var ddcEndpoints: [DDCDisplayEndpoint] = []
    @Published var volume: Double = 0.5
    @Published var isMuted: Bool = false
    @Published var volumeMode: VolumeControlMode = .unsupported
    @Published var volumeTargetName: String?
    @Published var ddcVolumes: [Int: Double] = [:]
    @Published var ddcMuted: [Int: Bool] = [:]
    @Published var inputProtocolMode: InputSourceProtocolMode = .auto

    @Published var launchAtLoginEnabled: Bool = false
    @Published var autoRestoreOnQuit: Bool = true
    @Published var isPrivateAPIAvailable: Bool = true
    @Published var errorBanner: String?

    private let displayManager: DisplayManager
    private let audioManager: AudioManager
    private let launchAtLogin: LaunchAtLoginManager
    private let onOpenLayoutEditor: () -> Void
    private let onPromptSavePreset: () -> Void
    private let onToggleAutoRestore: () -> Void
    private let onQuit: () -> Void
    private let onStatusChanged: () -> Void

    private static let inputProtocolKey = "MonitorBlock.inputProtocolMode"

    private var pendingVolumeWorkItem: DispatchWorkItem?
    private var pendingDDCWorkItems: [Int: DispatchWorkItem] = [:]

    init(
        displayManager: DisplayManager,
        audioManager: AudioManager,
        launchAtLogin: LaunchAtLoginManager,
        autoRestoreOnQuit: Bool,
        onOpenLayoutEditor: @escaping () -> Void,
        onPromptSavePreset: @escaping () -> Void,
        onToggleAutoRestore: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onStatusChanged: @escaping () -> Void
    ) {
        self.displayManager = displayManager
        self.audioManager = audioManager
        self.launchAtLogin = launchAtLogin
        self.autoRestoreOnQuit = autoRestoreOnQuit
        self.onOpenLayoutEditor = onOpenLayoutEditor
        self.onPromptSavePreset = onPromptSavePreset
        self.onToggleAutoRestore = onToggleAutoRestore
        self.onQuit = onQuit
        self.onStatusChanged = onStatusChanged
        if let raw = UserDefaults.standard.string(forKey: Self.inputProtocolKey),
           let saved = InputSourceProtocolMode(rawValue: raw) {
            self.inputProtocolMode = saved
        }
        refresh(readHardwareDDC: false)
    }

    func refresh(readHardwareDDC: Bool = false, autoRestoreValue: Bool? = nil) {
        if let autoRestoreValue {
            autoRestoreOnQuit = autoRestoreValue
        }
        isPrivateAPIAvailable = displayManager.isPrivateAPIAvailable
        displays = displayManager.listDisplays(includeBuiltin: true)
        presets = displayManager.listPresets()
        launchAtLoginEnabled = launchAtLogin.isEnabled

        audioDevices = audioManager.listOutputDevices()
        let snapshot = audioManager.currentVolumeSnapshot(readHardwareDDC: readHardwareDDC)
        volume = snapshot.volume
        isMuted = snapshot.isMuted
        volumeMode = snapshot.mode
        volumeTargetName = snapshot.deviceName

        ddcEndpoints = audioManager.listDDCEndpoints()
        for ep in ddcEndpoints {
            if let vol = ep.currentVolume {
                ddcVolumes[ep.index] = Double(vol) / 100.0
            } else if ddcVolumes[ep.index] == nil {
                ddcVolumes[ep.index] = 0.5
            }
            ddcMuted[ep.index] = ep.isMuted
        }
    }

    func hasDisableRule(for uuid: String) -> Bool {
        displayManager.disableRule(forDisplayUUID: uuid) != nil
    }

    var hasActiveExternal: Bool {
        displays.contains { !$0.isBuiltin && $0.isActive }
    }

    var hasAnyDisabledDisplay: Bool {
        displays.contains { !$0.isActive || $0.disabledByApp }
    }

    // MARK: - Display Actions

    func setDisplay(_ display: DisplayInfo, enabled: Bool) {
        errorBanner = nil
        do {
            try displayManager.setDisplay(id: display.id, enabled: enabled)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            errorBanner = error.localizedDescription
            refresh(readHardwareDDC: false)
        }
    }

    func disableAllExternal() {
        errorBanner = nil
        do {
            try displayManager.disableAllExternal()
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func enableAllDisplays() {
        errorBanner = nil
        do {
            try displayManager.enableAllDisplays()
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func identifyDisplays() {
        DisplayIdentifierOverlay.shared.identify(displays: displays)
    }

    func applyPreset(_ preset: LayoutPreset) {
        errorBanner = nil
        do {
            try displayManager.applyPreset(id: preset.id)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    // MARK: - Audio Actions

    func selectAudioOutput(_ device: AudioOutputDevice) {
        errorBanner = nil
        if audioManager.selectOutputDevice(id: device.id) {
            refresh(readHardwareDDC: true)
        } else {
            errorBanner = "切换音频输出设备「\(device.name)」失败。"
        }
    }

    func updateMainVolume(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 1.0)
        volume = clamped
        if clamped > 0.001 && isMuted {
            isMuted = false
        }

        // CoreAudio 直接即时写入；DDC/CI 走 70ms 节流避免 I2C 拥塞
        switch volumeMode {
        case .coreAudio:
            _ = audioManager.setCurrentVolume(clamped)
        case .ddc(let idx, _):
            ddcVolumes[idx] = clamped
            pendingVolumeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                _ = self?.audioManager.setCurrentVolume(clamped)
            }
            pendingVolumeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        case .unsupported:
            break
        }
    }

    func toggleMainMute() {
        let nextMuted = !isMuted
        isMuted = nextMuted
        _ = audioManager.setCurrentMuted(nextMuted)
        let snap = audioManager.currentVolumeSnapshot(readHardwareDDC: false)
        volume = snap.volume
        isMuted = snap.isMuted
        if case .ddc(let idx, _) = snap.mode {
            ddcVolumes[idx] = snap.volume
            ddcMuted[idx] = snap.isMuted
        }
    }

    func updateDDCVolume(endpointIndex: Int, value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        ddcVolumes[endpointIndex] = clamped
        if clamped > 0.001 {
            ddcMuted[endpointIndex] = false
        }
        if case .ddc(let currentIdx, _) = volumeMode, currentIdx == endpointIndex {
            volume = clamped
            if clamped > 0.001 {
                isMuted = false
            }
        }

        pendingDDCWorkItems[endpointIndex]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let percent = Int((clamped * 100.0).rounded())
            _ = self?.audioManager.setDDCVolume(percent, endpointIndex: endpointIndex)
        }
        pendingDDCWorkItems[endpointIndex] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func toggleDDCMute(endpointIndex: Int) {
        let nextMuted = !(ddcMuted[endpointIndex] ?? false)
        _ = audioManager.setDDCMuted(nextMuted, endpointIndex: endpointIndex)
        refresh(readHardwareDDC: false)
    }

    func bindActiveAudioToDDC(endpointIndex: Int) {
        guard let active = audioDevices.first(where: \.isDefault) else { return }
        audioManager.bindDDCEndpoint(endpointIndex, forAudioDeviceUID: active.uid)
        refresh(readHardwareDDC: true)
    }

    func cycleInputProtocolMode() {
        inputProtocolMode = inputProtocolMode.next
        UserDefaults.standard.set(inputProtocolMode.rawValue, forKey: Self.inputProtocolKey)
    }

    func switchInputSource(_ source: DisplayInputSource, endpointIndex: Int) {
        errorBanner = nil
        let ok = audioManager.setDisplayInputSource(
            source,
            endpointIndex: endpointIndex,
            protocolMode: inputProtocolMode
        )
        if !ok {
            errorBanner = "发送切换输入源指令（\(source.label)）失败，可尝试点击右上角切换「标准 0x60 / LG 0xF4」协议模式。"
        }
    }

    var activeDDCEndpointIndex: Int? {
        if case .ddc(let idx, _) = volumeMode {
            return idx
        }
        return nil
    }

    /// 为同名音频输出设备（如两台 LG HDR 4K）生成带 #1 / #2 区分后缀的显示名
    func displayTitle(for device: AudioOutputDevice) -> String {
        let sameName = audioDevices.filter { $0.name == device.name }
        guard sameName.count > 1,
              let idx = sameName.firstIndex(where: { $0.id == device.id }) else {
            return device.name
        }
        return "\(device.name) #\(idx + 1)"
    }

    /// 为同名 DDC 端点生成带 #1 / #2 区分后缀的显示名
    func displayTitle(for endpoint: DDCDisplayEndpoint) -> String {
        let sameName = ddcEndpoints.filter { $0.name == endpoint.name }
        guard sameName.count > 1,
              let idx = sameName.firstIndex(where: { $0.index == endpoint.index }) else {
            return endpoint.name
        }
        return "\(endpoint.name) #\(idx + 1)"
    }

    // MARK: - App Actions

    func toggleLaunchAtLogin() {
        errorBanner = nil
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            launchAtLoginEnabled = launchAtLogin.isEnabled
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func toggleAutoRestore() {
        onToggleAutoRestore()
    }

    func openLayoutEditor() {
        onOpenLayoutEditor()
    }

    func promptSavePreset() {
        onPromptSavePreset()
    }

    func quitApp() {
        onQuit()
    }
}

// MARK: - Control Center Popover View

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarPopoverViewModel

    var body: some View {
        VStack(spacing: 10) {
            headerBar

            if let error = viewModel.errorBanner {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        viewModel.errorBanner = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.orange.opacity(0.14))
                .cornerRadius(8)
            }

            if !viewModel.isPrivateAPIAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                    Text("当前系统不支持软断开 API，仅支持布局与音频控制。")
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    displaysCard
                    if !viewModel.ddcEndpoints.isEmpty {
                        inputSourceCard
                    }
                    audioCard
                    presetsCard
                }
            }
            .frame(maxHeight: 520)

            footerBar
        }
        .padding(12)
        .frame(width: 364)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
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
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            headerIconButton(symbol: "sparkles.tv", help: "识别显示器（屏幕闪显名称）") {
                viewModel.identifyDisplays()
            }
            headerIconButton(symbol: "rectangle.3.group", help: "命名、布局与关闭规则设置") {
                viewModel.openLayoutEditor()
            }
            headerIconButton(symbol: "arrow.clockwise", help: "刷新状态") {
                viewModel.refresh(readHardwareDDC: true)
            }
        }
    }

    private func headerIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Displays Card

    private var displaysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("显示器", systemImage: "display.2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if viewModel.hasActiveExternal {
                    Button("关全部外接") {
                        viewModel.disableAllExternal()
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                if viewModel.hasAnyDisabledDisplay {
                    Button("全部恢复") {
                        viewModel.enableAllDisplays()
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }

            if viewModel.displays.isEmpty {
                Text("未检测到显示器")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.displays) { display in
                        displayRow(display)
                    }
                }
            }
        }
        .padding(10)
        .background(cardBackground)
    }

    private func displayRow(_ display: DisplayInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(display.isActive ? .accentColor : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(display.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if display.isMain {
                        tagBadge("主屏", color: .accentColor)
                    }
                    if display.isBuiltin {
                        tagBadge("内置", color: .secondary)
                    }
                    if viewModel.hasDisableRule(for: display.uuid) {
                        tagBadge("规则", color: .purple)
                    }
                }

                HStack(spacing: 6) {
                    if let res = display.resolutionText {
                        Text(res)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                    if !display.isActive {
                        Text("已停用")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { display.isActive },
                    set: { viewModel.setDisplay(display, enabled: $0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.035))
        .cornerRadius(8)
    }

    // MARK: - Input Source Card

    private var inputSourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("信号输入源", systemImage: "cable.connector.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    viewModel.cycleInputProtocolMode()
                } label: {
                    tagBadge(viewModel.inputProtocolMode.label, color: .indigo)
                }
                .buttonStyle(.plain)
                .help("点击切换协议模式：自动（同时适配标准与 LG）/ 仅标准 MCCS 0x60 / 仅 LG 0xF4")
            }

            VStack(spacing: 6) {
                ForEach(viewModel.ddcEndpoints) { ep in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(viewModel.displayTitle(for: ep))
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            ForEach(DisplayInputSource.allCases) { source in
                                Button(source.label) {
                                    viewModel.switchInputSource(source, endpointIndex: ep.index)
                                }
                                .font(.system(size: 10.5, weight: .medium))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035))
                    .cornerRadius(8)
                }
            }
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Audio Card

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("声音与输出", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if let badge = viewModel.volumeMode.badgeText {
                    let badgeColor: Color = {
                        switch viewModel.volumeMode {
                        case .coreAudio: return .blue
                        case .ddc: return .teal
                        case .unsupported: return .secondary
                        }
                    }()
                    tagBadge(badge, color: badgeColor)
                }
            }

            // 主音量控制滑块（CoreAudio 或自动绑定的外接屏 DDC 音量）
            VStack(spacing: 6) {
                if let targetName = viewModel.volumeTargetName {
                    HStack(spacing: 4) {
                        Text("主音量目标：")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Text(mainTargetDisplayTitle(fallback: targetName))
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        viewModel.toggleMainMute()
                    } label: {
                        Image(systemName: volumeSymbol(level: viewModel.volume, muted: viewModel.isMuted))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(viewModel.isMuted ? .secondary : .accentColor)
                            .frame(width: 24, height: 24)
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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }

                // 直接在主音量下方整合显示所有外接屏 DDC 音量（无需折叠展开，每台自带独立静音 + 滑块 + 一键联动）
                if !viewModel.ddcEndpoints.isEmpty {
                    let endpointsToShow: [DDCDisplayEndpoint] = {
                        if viewModel.ddcEndpoints.count == 1,
                           viewModel.activeDDCEndpointIndex == viewModel.ddcEndpoints[0].index {
                            return []
                        }
                        return viewModel.ddcEndpoints
                    }()

                    if !endpointsToShow.isEmpty {
                        Divider()
                            .padding(.vertical, 1)

                        ForEach(endpointsToShow) { ep in
                            let epVol = viewModel.ddcVolumes[ep.index] ?? 0.5
                            let epMuted = viewModel.ddcMuted[ep.index] ?? false
                            let isLinkedToMain = (viewModel.activeDDCEndpointIndex == ep.index)
                            let epTitle = viewModel.displayTitle(for: ep)

                            HStack(spacing: 6) {
                                Button {
                                    viewModel.toggleDDCMute(endpointIndex: ep.index)
                                } label: {
                                    Image(systemName: volumeSymbol(level: epVol, muted: epMuted))
                                        .font(.system(size: 12))
                                        .foregroundColor(epMuted ? .secondary : .teal)
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)

                                Text(epTitle)
                                    .font(.system(size: 11, weight: isLinkedToMain ? .semibold : .regular))
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
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 28, alignment: .trailing)

                                if viewModel.activeDDCEndpointIndex != nil {
                                    Button(isLinkedToMain ? "已联动" : "联动") {
                                        viewModel.bindActiveAudioToDDC(endpointIndex: ep.index)
                                    }
                                    .font(.system(size: 9.5, weight: .medium))
                                    .buttonStyle(.bordered)
                                    .tint(isLinkedToMain ? .teal : .secondary)
                                    .controlSize(.mini)
                                    .help("将当前音频输出的主音量绑定到此显示器（会自动记住）")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.035))
            .cornerRadius(8)

            // 音频输出设备切换列表
            if !viewModel.audioDevices.isEmpty {
                VStack(spacing: 4) {
                    ForEach(viewModel.audioDevices) { device in
                        audioDeviceRow(device)
                    }
                }
            }
        }
        .padding(10)
        .background(cardBackground)
    }

    private func audioDeviceRow(_ device: AudioOutputDevice) -> some View {
        Button {
            viewModel.selectAudioOutput(device)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.transport.symbolName)
                    .font(.system(size: 12))
                    .foregroundColor(device.isDefault ? .white : .secondary)
                    .frame(width: 22, height: 22)
                    .background(device.isDefault ? Color.accentColor : Color.secondary.opacity(0.15))
                    .clipShape(Circle())

                Text(viewModel.displayTitle(for: device))
                    .font(.system(size: 12, weight: device.isDefault ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if device.isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(device.isDefault ? Color.accentColor.opacity(0.12) : Color.clear)
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Presets Card

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("布局预设", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("+ 保存当前") {
                    viewModel.promptSavePreset()
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if viewModel.presets.isEmpty {
                Text("暂无预设，点击右上角可快速保存当前多屏布局。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.presets) { preset in
                            Button(preset.name) {
                                viewModel.applyPreset(preset)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
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
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: - Visual Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }

    private func tagBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14))
            .cornerRadius(4)
    }

    private func mainTargetDisplayTitle(fallback: String) -> String {
        if let activeIdx = viewModel.activeDDCEndpointIndex,
           let ep = viewModel.ddcEndpoints.first(where: { $0.index == activeIdx }) {
            return viewModel.displayTitle(for: ep)
        }
        if let activeDevice = viewModel.audioDevices.first(where: \.isDefault) {
            return viewModel.displayTitle(for: activeDevice)
        }
        return fallback
    }

    private func volumeSymbol(level: Double, muted: Bool) -> String {
        if muted || level <= 0.001 {
            return "speaker.slash.fill"
        } else if level < 0.34 {
            return "speaker.wave.1.fill"
        } else if level < 0.67 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
