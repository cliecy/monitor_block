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
    @Published var displayToDDCIndex: [String: Int] = [:] // display.uuid -> ddcEndpoint.index
    @Published var inputStatuses: [Int: DisplayInputStatus] = [:] // ddcEndpoint.index -> status
    @Published var switchingInputs: [Int: DisplayInputSource] = [:] // ddcEndpoint.index -> switching target

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
    @Published var statusBanner: (text: String, isError: Bool)?

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
    private var bannerClearWorkItem: DispatchWorkItem?

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
        var mapping: [String: Int] = [:]
        for display in displays where !display.isBuiltin && display.isActive {
            if let ep = audioManager.matchDDCEndpoint(for: display, allDisplays: displays, endpoints: ddcEndpoints) {
                mapping[display.uuid] = ep.index
            }
        }
        displayToDDCIndex = mapping

        for ep in ddcEndpoints {
            if let vol = ep.currentVolume {
                ddcVolumes[ep.index] = Double(vol) / 100.0
            } else if ddcVolumes[ep.index] == nil {
                ddcVolumes[ep.index] = 0.5
            }
            ddcMuted[ep.index] = ep.isMuted
            if let cachedStatus = audioManager.cachedDisplayInputStatus(endpointIndex: ep.index) {
                inputStatuses[ep.index] = cachedStatus
            }
        }

        if readHardwareDDC {
            refreshAllInputStatusesAsync()
        }
    }

    func refreshAllInputStatusesAsync() {
        let indices = ddcEndpoints.map(\.index)
        guard !indices.isEmpty else { return }
        let audioMgr = audioManager

        Task.detached(priority: .userInitiated) {
            var results: [Int: DisplayInputStatus] = [:]
            for idx in indices {
                results[idx] = audioMgr.readDisplayInputStatus(endpointIndex: idx)
            }
            let finalResults = results
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (idx, status) in finalResults {
                    self.inputStatuses[idx] = status
                }
            }
        }
    }

    func refreshSingleInputStatusAsync(endpointIndex: Int) {
        let audioMgr = audioManager
        Task.detached(priority: .userInitiated) {
            let status = audioMgr.readDisplayInputStatus(endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                self?.inputStatuses[endpointIndex] = status
            }
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
        clearBanner()
        do {
            try displayManager.setDisplay(id: display.id, enabled: enabled)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
            refresh(readHardwareDDC: false)
        }
    }

    func disableAllExternal() {
        clearBanner()
        do {
            try displayManager.disableAllExternal()
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func enableAllDisplays() {
        clearBanner()
        do {
            try displayManager.enableAllDisplays()
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func identifyDisplays() {
        DisplayIdentifierOverlay.shared.identify(displays: displays)
    }

    func applyPreset(_ preset: LayoutPreset) {
        clearBanner()
        do {
            try displayManager.applyPreset(id: preset.id)
            showBanner("已切换布局预设「\(preset.name)」", isError: false)
            refresh(readHardwareDDC: false)
            onStatusChanged()
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Input Source Actions (Async, Non-blocking)

    func setInputProtocolMode(_ mode: InputSourceProtocolMode) {
        inputProtocolMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.inputProtocolKey)
        showBanner("输入源协议已切换为：\(mode.label)", isError: false)
    }

    func switchInputSource(_ source: DisplayInputSource, endpointIndex: Int, displayName: String) {
        switchingInputs[endpointIndex] = source
        showBanner("正在将「\(displayName)」切换至 \(source.label)…", isError: false, autoClear: false)

        let audioMgr = audioManager
        let mode = inputProtocolMode

        Task.detached(priority: .userInitiated) {
            let ok = audioMgr.setDisplayInputSource(source, endpointIndex: endpointIndex, protocolMode: mode)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.switchingInputs.removeValue(forKey: endpointIndex)
                if ok {
                    // 立即在 UI 上先更新激活高亮，给用户明确的切换反馈
                    let existing = self.inputStatuses[endpointIndex]
                    self.inputStatuses[endpointIndex] = DisplayInputStatus(
                        activeSource: source,
                        rawRead: existing?.rawRead ?? DDCInputReadResult(),
                        calibratedCodes: existing?.calibratedCodes ?? [:]
                    )
                    self.showBanner("已发送信号源切换：\(displayName) → \(source.label)", isError: false)
                } else {
                    self.showBanner("「\(displayName)」切换至 \(source.label) 失败，可点击右侧 ⚙︎ 校准该端口。", isError: true)
                }
            }

            // 等待显示器完成握手后重新回读真实硬件状态
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let updatedStatus = audioMgr.readDisplayInputStatus(endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if updatedStatus.activeSource != nil || !updatedStatus.rawRead.isEmpty {
                    self.inputStatuses[endpointIndex] = updatedStatus
                }
            }
        }
    }

    func calibrateCurrentInput(as source: DisplayInputSource, endpointIndex: Int, displayName: String) {
        showBanner("正在读取「\(displayName)」当前端口硬件码…", isError: false, autoClear: false)
        let audioMgr = audioManager

        Task.detached(priority: .userInitiated) {
            let code = audioMgr.calibrateCurrentInputSource(as: source, endpointIndex: endpointIndex)
            let refreshed = audioMgr.cachedDisplayInputStatus(endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let refreshed {
                    self.inputStatuses[endpointIndex] = refreshed
                }
                if let code {
                    self.showBanner("校准成功：「\(displayName)」的 \(source.label) 已绑定为 \(code.hexSummary)", isError: false)
                } else {
                    self.showBanner("未能从「\(displayName)」读出当前端口码，请确认线缆支持 DDC/CI。", isError: true)
                }
            }
        }
    }

    func resetInputCalibration(endpointIndex: Int, displayName: String) {
        audioManager.resetInputCalibration(endpointIndex: endpointIndex)
        refreshSingleInputStatusAsync(endpointIndex: endpointIndex)
        showBanner("已重置「\(displayName)」的输入源校准", isError: false)
    }

    // MARK: - Audio Actions

    func selectAudioOutput(_ device: AudioOutputDevice) {
        clearBanner()
        if audioManager.selectOutputDevice(id: device.id) {
            refresh(readHardwareDDC: true)
        } else {
            showBanner("切换音频输出设备「\(device.name)」失败。", isError: true)
        }
    }

    func updateMainVolume(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 1.0)
        volume = clamped
        if clamped > 0.001 && isMuted {
            isMuted = false
        }

        switch volumeMode {
        case .coreAudio:
            _ = audioManager.setCurrentVolume(clamped)
        case .ddc(let idx, _):
            ddcVolumes[idx] = clamped
            if clamped > 0.001 {
                ddcMuted[idx] = false
            }
            pendingVolumeWorkItem?.cancel()
            let audioMgr = audioManager
            let work = DispatchWorkItem {
                Task.detached(priority: .userInitiated) {
                    _ = audioMgr.setCurrentVolume(clamped)
                }
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
        let audioMgr = audioManager

        if case .coreAudio = volumeMode {
            _ = audioMgr.setCurrentMuted(nextMuted)
            let snap = audioMgr.currentVolumeSnapshot(readHardwareDDC: false)
            volume = snap.volume
            isMuted = snap.isMuted
        } else {
            Task.detached(priority: .userInitiated) {
                _ = audioMgr.setCurrentMuted(nextMuted)
                let snap = audioMgr.currentVolumeSnapshot(readHardwareDDC: false)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.volume = snap.volume
                    self.isMuted = snap.isMuted
                    if case .ddc(let idx, _) = snap.mode {
                        self.ddcVolumes[idx] = snap.volume
                        self.ddcMuted[idx] = snap.isMuted
                    }
                }
            }
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
        let audioMgr = audioManager
        let work = DispatchWorkItem {
            let percent = Int((clamped * 100.0).rounded())
            Task.detached(priority: .userInitiated) {
                _ = audioMgr.setDDCVolume(percent, endpointIndex: endpointIndex)
            }
        }
        pendingDDCWorkItems[endpointIndex] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func toggleDDCMute(endpointIndex: Int) {
        let nextMuted = !(ddcMuted[endpointIndex] ?? false)
        ddcMuted[endpointIndex] = nextMuted
        let audioMgr = audioManager
        Task.detached(priority: .userInitiated) {
            _ = audioMgr.setDDCMuted(nextMuted, endpointIndex: endpointIndex)
            await MainActor.run { [weak self] in
                self?.refresh(readHardwareDDC: false)
            }
        }
    }

    func bindActiveAudioToDDC(endpointIndex: Int) {
        guard let active = audioDevices.first(where: \.isDefault) else { return }
        audioManager.bindDDCEndpoint(endpointIndex, forAudioDeviceUID: active.uid)
        refresh(readHardwareDDC: true)
    }

    var activeDDCEndpointIndex: Int? {
        if case .ddc(let idx, _) = volumeMode {
            return idx
        }
        return nil
    }

    func displayTitle(for device: AudioOutputDevice) -> String {
        let sameName = audioDevices.filter { $0.name == device.name }
        guard sameName.count > 1,
              let idx = sameName.firstIndex(where: { $0.id == device.id }) else {
            return device.name
        }
        return "\(device.name) #\(idx + 1)"
    }

    /// 优先返回用户为对应显示器设置的自定义名称（如“左 LG”），避免出现难以区分的 #1/#2
    func displayTitle(for endpoint: DDCDisplayEndpoint) -> String {
        if let matchedUUID = displayToDDCIndex.first(where: { $0.value == endpoint.index })?.key,
           let matchedDisplay = displays.first(where: { $0.uuid == matchedUUID }) {
            return matchedDisplay.name
        }
        let sameName = ddcEndpoints.filter { $0.name == endpoint.name }
        guard sameName.count > 1,
              let idx = sameName.firstIndex(where: { $0.index == endpoint.index }) else {
            return endpoint.name
        }
        return "\(endpoint.name) #\(idx + 1)"
    }

    // MARK: - App Actions

    func toggleLaunchAtLogin() {
        clearBanner()
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            launchAtLoginEnabled = launchAtLogin.isEnabled
        } catch {
            showBanner(error.localizedDescription, isError: true)
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

    // MARK: - Banner Helpers

    private func showBanner(_ text: String, isError: Bool, autoClear: Bool = true) {
        bannerClearWorkItem?.cancel()
        statusBanner = (text, isError)
        guard autoClear else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.statusBanner = nil
        }
        bannerClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 5.0 : 3.2), execute: work)
    }

    func clearBanner() {
        bannerClearWorkItem?.cancel()
        statusBanner = nil
    }
}

// MARK: - Control Center Popover View

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarPopoverViewModel

    var body: some View {
        VStack(spacing: 10) {
            headerBar

            if let banner = viewModel.statusBanner {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(banner.isError ? .orange : .accentColor)
                    Text(banner.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        viewModel.clearBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background((banner.isError ? Color.orange : Color.accentColor).opacity(0.14))
                .cornerRadius(8)
            }

            if !viewModel.isPrivateAPIAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                    Text("当前系统不支持软断开 API，仅支持布局、输入源与音频控制。")
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
                    audioCard
                    presetsCard
                }
            }
            .frame(maxHeight: 540)

            footerBar
        }
        .padding(12)
        .frame(width: 376)
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
            headerIconButton(symbol: "arrow.clockwise", help: "刷新显示器、输入源与音频状态") {
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

    // MARK: - Displays Card (含内嵌输入源切换条)

    private var displaysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("显示器与信号源", systemImage: "display.2")
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
                VStack(spacing: 7) {
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
        let ddcIndex = viewModel.displayToDDCIndex[display.uuid]

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(display.isActive ? .accentColor : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(display.name)
                            .font(.system(size: 12.5, weight: .semibold))
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
                        } else if let idx = ddcIndex,
                                  let activeSrc = viewModel.inputStatuses[idx]?.activeSource {
                            Text("当前：\(activeSrc.label)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.accentColor)
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

            // 内嵌该外接显示器的信号输入源切换条（自动高亮当前激活输入源 + 校准菜单）
            if display.isActive, let idx = ddcIndex {
                inputSourceStrip(endpointIndex: idx, displayName: display.name)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.038))
        .cornerRadius(8)
    }

    private func inputSourceStrip(endpointIndex: Int, displayName: String) -> some View {
        let status = viewModel.inputStatuses[endpointIndex]
        let activeSource = status?.activeSource
        let switchingTarget = viewModel.switchingInputs[endpointIndex]

        return HStack(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(DisplayInputSource.allCases) { source in
                    let isSelected = (switchingTarget == source) || (switchingTarget == nil && activeSource == source)
                    let isSwitchingThis = (switchingTarget == source)
                    let isCalibrated = (status?.calibratedCodes[source] != nil)

                    Button {
                        viewModel.switchInputSource(source, endpointIndex: endpointIndex, displayName: displayName)
                    } label: {
                        HStack(spacing: 2) {
                            if isSwitchingThis {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                            }
                            Text(source.label)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                            if isCalibrated && !isSwitchingThis {
                                Circle()
                                    .fill(isSelected ? Color.white : Color.teal)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .foregroundColor(isSelected ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(switchingTarget != nil)
                }
            }

            // 校准与协议设置菜单（解决各型号 USB-C 硬件码不一致的问题）
            Menu {
                Text("硬件读出：\(status?.rawRead.rawSummary ?? "读取中…")")

                Divider()

                Menu("将当前亮屏端口校准为…") {
                    ForEach(DisplayInputSource.allCases) { source in
                        let existing = status?.calibratedCodes[source]
                        let suffix = existing.map { " (\($0.hexSummary))" } ?? ""
                        Button("\(source.label)\(suffix)") {
                            viewModel.calibrateCurrentInput(
                                as: source,
                                endpointIndex: endpointIndex,
                                displayName: displayName
                            )
                        }
                    }
                }

                Menu("切换协议：\(viewModel.inputProtocolMode.label)") {
                    ForEach(InputSourceProtocolMode.allCases) { mode in
                        Button {
                            viewModel.setInputProtocolMode(mode)
                        } label: {
                            if viewModel.inputProtocolMode == mode {
                                Text("✓ \(mode.label)")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }

                Divider()

                Button("重新读取当前输入源") {
                    viewModel.refreshSingleInputStatusAsync(endpointIndex: endpointIndex)
                }

                if !(status?.calibratedCodes.isEmpty ?? true) {
                    Button("重置此屏端口校准", role: .destructive) {
                        viewModel.resetInputCalibration(endpointIndex: endpointIndex, displayName: displayName)
                    }
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(5)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("查看硬件输入码、校准 USB-C 等端口编码或切换协议模式")
        }
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

                // 整合显示所有外接屏 DDC 音量（使用自定义显示器名称）
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
                                    .frame(width: 84, alignment: .leading)

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
