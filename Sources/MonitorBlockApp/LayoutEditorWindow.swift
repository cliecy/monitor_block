import AppKit
import CoreGraphics
import MonitorBlockCore
import SwiftUI

@MainActor
final class LayoutEditorWindowController: NSWindowController {
    private let viewModel: LayoutEditorViewModel

    init(manager: DisplayManager, onDidMutate: @escaping () -> Void) {
        self.viewModel = LayoutEditorViewModel(manager: manager, onDidMutate: onDidMutate)
        let rootView = LayoutEditorRootView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MonitorBlock — 布局与关闭规则"
        window.minSize = NSSize(width: 680, height: 500)
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndRefresh() {
        viewModel.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class LayoutEditorViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case arrangement = "实时布局"
        case disableRules = "关闭后布局规则"
        var id: String { rawValue }
    }

    enum RelativeSide {
        case left, right, top, bottom
    }

    @Published var selectedTab: Tab = .arrangement
    @Published var allDisplays: [DisplayInfo] = []
    @Published var externalDisplays: [DisplayInfo] = []

    // Tab 1: 实时布局
    @Published var livePlacements: [DisplayPlacement] = []
    @Published var selectedLiveUUID: String?
    @Published var presets: [LayoutPreset] = []
    @Published var newPresetName: String = ""

    // Tab 2: 关闭后布局规则
    @Published var selectedTargetExternalUUID: String?
    @Published var rulePlacements: [DisplayPlacement] = []
    @Published var selectedRuleUUID: String?
    @Published var restorePreviousOnEnable: Bool = true
    @Published var savedRuleUUIDs: Set<String> = []

    @Published var statusMessage: String?
    @Published var isErrorMessage: Bool = false

    let liveDragSession = CanvasDragSession()
    let ruleDragSession = CanvasDragSession()

    private let manager: DisplayManager
    private let onDidMutate: () -> Void

    init(manager: DisplayManager, onDidMutate: @escaping () -> Void) {
        self.manager = manager
        self.onDidMutate = onDidMutate
        reload()
    }

    func reload() {
        allDisplays = manager.listDisplays(includeBuiltin: true)
        externalDisplays = allDisplays.filter { !$0.isBuiltin }
        livePlacements = manager.captureCurrentLayout()
        presets = manager.listPresets()
        savedRuleUUIDs = Set(manager.listDisableRules().map(\.targetDisplayUUID))

        if selectedLiveUUID == nil || !livePlacements.contains(where: { $0.uuid == selectedLiveUUID }) {
            selectedLiveUUID = livePlacements.first?.uuid
        }

        if selectedTargetExternalUUID == nil || !externalDisplays.contains(where: { $0.uuid == selectedTargetExternalUUID }) {
            selectedTargetExternalUUID = externalDisplays.first?.uuid
        }
        loadRuleForSelectedTarget()
    }

    // MARK: - Tab 1 Actions

    func applyLiveLayout() {
        do {
            try manager.applyLayout(livePlacements)
            setStatus("已应用当前布局", isError: false)
            reload()
            onDidMutate()
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func saveCurrentAsPreset() {
        let preset = manager.savePreset(name: newPresetName, placements: livePlacements)
        newPresetName = ""
        presets = manager.listPresets()
        setStatus("已保存预设「\(preset.name)」", isError: false)
        onDidMutate()
    }

    func applyPreset(_ preset: LayoutPreset) {
        do {
            try manager.applyPreset(id: preset.id)
            setStatus("已切换到预设「\(preset.name)」", isError: false)
            reload()
            onDidMutate()
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func deletePreset(_ preset: LayoutPreset) {
        manager.deletePreset(id: preset.id)
        presets = manager.listPresets()
        setStatus("已删除预设「\(preset.name)」", isError: false)
        onDidMutate()
    }

    // MARK: - Tab 2 Actions

    func selectTargetExternal(uuid: String) {
        selectedTargetExternalUUID = uuid
        loadRuleForSelectedTarget()
    }

    func loadRuleForSelectedTarget() {
        guard let targetUUID = selectedTargetExternalUUID else {
            rulePlacements = []
            selectedRuleUUID = nil
            return
        }

        if let existing = manager.disableRule(forDisplayUUID: targetUUID) {
            rulePlacements = existing.layoutOnDisable
            restorePreviousOnEnable = existing.restorePreviousOnEnable
        } else {
            // 默认基于当前屏幕列表，剔除目标屏幕后生成初始剩余布局
            let remaining = allDisplays.filter { $0.uuid != targetUUID }
            var placements = remaining.map {
                DisplayPlacement(
                    uuid: $0.uuid,
                    name: $0.name,
                    x: $0.originX,
                    y: $0.originY,
                    width: max($0.width, 1),
                    height: max($0.height, 1),
                    isMain: $0.isMain
                )
            }
            if !placements.isEmpty && !placements.contains(where: \.isMain) {
                placements[0].isMain = true
            }
            rulePlacements = Self.normalized(placements)
            restorePreviousOnEnable = true
        }

        if selectedRuleUUID == nil || !rulePlacements.contains(where: { $0.uuid == selectedRuleUUID }) {
            selectedRuleUUID = rulePlacements.first?.uuid
        }
    }

    func saveRuleForSelectedTarget() {
        guard let targetUUID = selectedTargetExternalUUID,
              let target = externalDisplays.first(where: { $0.uuid == targetUUID }) else {
            return
        }
        let normalized = Self.normalized(rulePlacements)
        let rule = DisableLayoutRule(
            targetDisplayUUID: targetUUID,
            targetDisplayName: target.name,
            layoutOnDisable: normalized,
            restorePreviousOnEnable: restorePreviousOnEnable
        )
        manager.saveDisableRule(rule)
        rulePlacements = normalized
        savedRuleUUIDs = Set(manager.listDisableRules().map(\.targetDisplayUUID))
        setStatus("已保存关闭「\(target.name)」后的布局规则", isError: false)
        onDidMutate()
    }

    func deleteRuleForSelectedTarget() {
        guard let targetUUID = selectedTargetExternalUUID,
              let target = externalDisplays.first(where: { $0.uuid == targetUUID }) else {
            return
        }
        manager.deleteDisableRule(forDisplayUUID: targetUUID)
        savedRuleUUIDs = Set(manager.listDisableRules().map(\.targetDisplayUUID))
        loadRuleForSelectedTarget()
        setStatus("已清除「\(target.name)」的关闭规则", isError: false)
        onDidMutate()
    }

    func captureCurrentIntoRule() {
        guard let targetUUID = selectedTargetExternalUUID else { return }
        let current = manager.captureCurrentLayout().filter { $0.uuid != targetUUID }
        guard !current.isEmpty else {
            setStatus("当前没有可捕获的剩余活跃屏幕", isError: true)
            return
        }
        rulePlacements = Self.normalized(current)
        selectedRuleUUID = rulePlacements.first?.uuid
        setStatus("已捕获当前剩余屏幕布局，请点击「保存规则」生效", isError: false)
    }

    // MARK: - Shared Arrangement Helpers

    func markAsMain(uuid: String, inLive: Bool) {
        if inLive {
            livePlacements = Self.settingMain(uuid: uuid, in: livePlacements)
        } else {
            rulePlacements = Self.settingMain(uuid: uuid, in: rulePlacements)
        }
    }

    func placeSelected(_ side: RelativeSide, inLive: Bool) {
        let selectedUUID = inLive ? selectedLiveUUID : selectedRuleUUID
        guard let selectedUUID else { return }
        var list = inLive ? livePlacements : rulePlacements
        guard let targetIdx = list.firstIndex(where: { $0.uuid == selectedUUID }) else { return }
        guard let anchor = list.first(where: { $0.isMain && $0.uuid != selectedUUID })
                ?? list.first(where: { $0.uuid != selectedUUID }) else {
            return
        }

        let target = list[targetIdx]
        switch side {
        case .left:
            list[targetIdx].x = anchor.x - target.width
            list[targetIdx].y = anchor.y + (anchor.height - target.height) / 2
        case .right:
            list[targetIdx].x = anchor.x + anchor.width
            list[targetIdx].y = anchor.y + (anchor.height - target.height) / 2
        case .top:
            list[targetIdx].x = anchor.x + (anchor.width - target.width) / 2
            list[targetIdx].y = anchor.y - target.height
        case .bottom:
            list[targetIdx].x = anchor.x + (anchor.width - target.width) / 2
            list[targetIdx].y = anchor.y + anchor.height
        }

        let updated = Self.normalized(list)
        if inLive {
            livePlacements = updated
        } else {
            rulePlacements = updated
        }
    }

    static func settingMain(uuid: String, in placements: [DisplayPlacement]) -> [DisplayPlacement] {
        var copy = placements
        for idx in copy.indices {
            copy[idx].isMain = (copy[idx].uuid == uuid)
        }
        return normalized(copy)
    }

    static func normalized(_ placements: [DisplayPlacement]) -> [DisplayPlacement] {
        guard !placements.isEmpty else { return [] }
        var copy = placements
        if !copy.contains(where: \.isMain) {
            copy[0].isMain = true
        }
        let main = copy.first(where: \.isMain) ?? copy[0]
        let dx = main.x
        let dy = main.y
        for idx in copy.indices {
            copy[idx].x -= dx
            copy[idx].y -= dy
        }
        return copy
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusMessage = text
        isErrorMessage = isError
    }
}

// MARK: - SwiftUI Views

struct LayoutEditorRootView: View {
    @ObservedObject var viewModel: LayoutEditorViewModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $viewModel.selectedTab) {
                ForEach(LayoutEditorViewModel.Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if viewModel.selectedTab == .arrangement {
                liveArrangementView
            } else {
                disableRulesView
            }

            if let message = viewModel.statusMessage {
                HStack {
                    Image(systemName: viewModel.isErrorMessage ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(viewModel.isErrorMessage ? .orange : .green)
                    Text(message)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    private var liveArrangementView: some View {
        VStack(spacing: 12) {
            DisplayArrangementCanvas(
                placements: $viewModel.livePlacements,
                selectedUUID: $viewModel.selectedLiveUUID,
                dragSession: viewModel.liveDragSession
            )
            .padding(.horizontal, 16)

            arrangementControls(
                selectedUUID: viewModel.selectedLiveUUID,
                placements: viewModel.livePlacements,
                inLive: true
            )
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Button("刷新当前布局") {
                    viewModel.reload()
                }
                Button("应用布局") {
                    viewModel.applyLiveLayout()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.livePlacements.isEmpty)

                Spacer()

                TextField("预设名称（如：办公三屏）", text: $viewModel.newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)

                Button("保存为预设") {
                    viewModel.saveCurrentAsPreset()
                }
                .disabled(viewModel.livePlacements.isEmpty)
            }
            .padding(.horizontal, 16)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("已保存的布局预设")
                    .font(.headline)
                if viewModel.presets.isEmpty {
                    Text("暂无预设。拖拽上方显示器排好位置后点击「保存为预设」即可在菜单栏一键切换。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.presets) { preset in
                                HStack(spacing: 6) {
                                    Button(preset.name) {
                                        viewModel.applyPreset(preset)
                                    }
                                    .buttonStyle(.bordered)
                                    Button {
                                        viewModel.deletePreset(preset)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.08))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var disableRulesView: some View {
        VStack(spacing: 12) {
            if viewModel.externalDisplays.isEmpty {
                Spacer()
                Text("未检测到外接显示器。连接外接显示器后即可为其配置“关闭后布局规则”。")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                HStack(spacing: 10) {
                    Text("当关闭此屏幕时：")
                        .font(.subheadline)
                    Picker(
                        "",
                        selection: Binding(
                            get: { viewModel.selectedTargetExternalUUID ?? "" },
                            set: { viewModel.selectTargetExternal(uuid: $0) }
                        )
                    ) {
                        ForEach(viewModel.externalDisplays) { display in
                            let badge = viewModel.savedRuleUUIDs.contains(display.uuid) ? "（已配置）" : ""
                            Text("\(display.name)\(badge)").tag(display.uuid)
                        }
                    }
                    .frame(width: 260)

                    Spacer()

                    Button("捕获当前剩余屏幕布局") {
                        viewModel.captureCurrentIntoRule()
                    }
                }
                .padding(.horizontal, 16)

                if viewModel.rulePlacements.isEmpty {
                    Text("关闭该屏幕后没有其他剩余屏幕可排布。")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    DisplayArrangementCanvas(
                        placements: $viewModel.rulePlacements,
                        selectedUUID: $viewModel.selectedRuleUUID,
                        dragSession: viewModel.ruleDragSession
                    )
                    .padding(.horizontal, 16)

                    arrangementControls(
                        selectedUUID: viewModel.selectedRuleUUID,
                        placements: viewModel.rulePlacements,
                        inLive: false
                    )
                    .padding(.horizontal, 16)
                }

                HStack {
                    Toggle("重新开启该屏幕时，自动恢复关闭前的原布局", isOn: $viewModel.restorePreviousOnEnable)

                    Spacer()

                    if let targetUUID = viewModel.selectedTargetExternalUUID,
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
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func arrangementControls(
        selectedUUID: String?,
        placements: [DisplayPlacement],
        inLive: Bool
    ) -> some View {
        let selected = placements.first(where: { $0.uuid == selectedUUID })
        HStack(spacing: 8) {
            if let selected {
                Text("已选中：\(selected.name)  (\(selected.x), \(selected.y))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("设为主屏") {
                    viewModel.markAsMain(uuid: selected.uuid, inLive: inLive)
                }
                .disabled(selected.isMain)

                if placements.count > 1 {
                    Button("靠左") { viewModel.placeSelected(.left, inLive: inLive) }
                    Button("靠右") { viewModel.placeSelected(.right, inLive: inLive) }
                    Button("靠上") { viewModel.placeSelected(.top, inLive: inLive) }
                    Button("靠下") { viewModel.placeSelected(.bottom, inLive: inLive) }
                }
            } else {
                Text("点击或拖拽画布中的显示器调整位置")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}

/// 可视化拖拽显示器画布（支持松手边缘吸附）
final class CanvasDragSession {
    var activeDragUUID: String?
    var dragStartOrigins: [String: (x: Int, y: Int)] = [:]
}

struct DisplayArrangementCanvas: View {
    @Binding var placements: [DisplayPlacement]
    @Binding var selectedUUID: String?
    let dragSession: CanvasDragSession

    var body: some View {
        GeometryReader { geo in
            let transform = computeTransform(canvasSize: geo.size)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                ForEach(placements) { item in
                    let rect = CGRect(
                        x: transform.offsetX + CGFloat(item.x) * transform.scale,
                        y: transform.offsetY + CGFloat(item.y) * transform.scale,
                        width: max(CGFloat(item.width) * transform.scale, 64),
                        height: max(CGFloat(item.height) * transform.scale, 44)
                    )
                    let isSelected = (selectedUUID == item.uuid)

                    displayTile(item: item, isSelected: isSelected)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    selectedUUID = item.uuid
                                    if dragSession.activeDragUUID != item.uuid {
                                        dragSession.activeDragUUID = item.uuid
                                        dragSession.dragStartOrigins = Dictionary(
                                            uniqueKeysWithValues: placements.map { ($0.uuid, ($0.x, $0.y)) }
                                        )
                                    }
                                    guard let start = dragSession.dragStartOrigins[item.uuid],
                                          let idx = placements.firstIndex(where: { $0.uuid == item.uuid }) else {
                                        return
                                    }
                                    let deltaX = Int((value.translation.width / transform.scale).rounded())
                                    let deltaY = Int((value.translation.height / transform.scale).rounded())
                                    placements[idx].x = start.x + deltaX
                                    placements[idx].y = start.y + deltaY
                                }
                                .onEnded { _ in
                                    if let idx = placements.firstIndex(where: { $0.uuid == item.uuid }) {
                                        snapDisplay(at: idx)
                                        placements = LayoutEditorViewModel.normalized(placements)
                                    }
                                    dragSession.activeDragUUID = nil
                                }
                        )
                }
            }
        }
        .frame(minHeight: 240, maxHeight: 280)
    }

    private func displayTile(item: DisplayPlacement, isSelected: Bool) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: isSelected ? 2 : 1)
                )

            if item.isMain {
                // 模拟 macOS 主屏顶部的白色菜单栏条
                Rectangle()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, 4)
                    .padding(.top, 3)
            }

            VStack(spacing: 2) {
                Spacer(minLength: 8)
                Text(item.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(item.width)×\(item.height)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                if item.isMain {
                    Text("主屏")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 6)
        }
    }

    private func computeTransform(canvasSize: CGSize) -> (scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        guard !placements.isEmpty else { return (0.08, canvasSize.width / 2, canvasSize.height / 2) }

        let minX = placements.map(\.x).min() ?? 0
        let minY = placements.map(\.y).min() ?? 0
        let maxX = placements.map { $0.x + $0.width }.max() ?? 1920
        let maxY = placements.map { $0.y + $0.height }.max() ?? 1080

        let contentW = CGFloat(max(maxX - minX, 800))
        let contentH = CGFloat(max(maxY - minY, 600))

        let pad: CGFloat = 48
        let usableW = max(canvasSize.width - pad * 2, 120)
        let usableH = max(canvasSize.height - pad * 2, 100)

        let scale = min(usableW / contentW, usableH / contentH, 0.12)
        let renderedW = contentW * scale
        let renderedH = contentH * scale

        let offsetX = (canvasSize.width - renderedW) / 2 - CGFloat(minX) * scale
        let offsetY = (canvasSize.height - renderedH) / 2 - CGFloat(minY) * scale
        return (scale, offsetX, offsetY)
    }

    /// 拖拽松手时，将当前屏幕自动吸附到最近的相邻屏幕边缘，避免缝隙或重叠
    private func snapDisplay(at index: Int) {
        guard placements.count > 1 else { return }
        let moving = placements[index]
        let others = placements.enumerated().filter { $0.offset != index }.map(\.element)

        var bestX = moving.x
        var bestY = moving.y
        var bestDistance = Double.greatestFiniteMagnitude

        for other in others {
            let candidates: [(Int, Int)] = [
                // 贴在 other 左侧
                (other.x - moving.width, clamp(moving.y, min: other.y - moving.height + 120, max: other.y + other.height - 120)),
                // 贴在 other 右侧
                (other.x + other.width, clamp(moving.y, min: other.y - moving.height + 120, max: other.y + other.height - 120)),
                // 贴在 other 上方
                (clamp(moving.x, min: other.x - moving.width + 120, max: other.x + other.width - 120), other.y - moving.height),
                // 贴在 other 下方
                (clamp(moving.x, min: other.x - moving.width + 120, max: other.x + other.width - 120), other.y + other.height)
            ]

            for (cx, cy) in candidates {
                let dx = Double(cx - moving.x)
                let dy = Double(cy - moving.y)
                let dist = hypot(dx, dy)
                if dist < bestDistance {
                    bestDistance = dist
                    bestX = cx
                    bestY = cy
                }
            }
        }

        placements[index].x = bestX
        placements[index].y = bestY
    }

    private func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        if lower > upper { return value }
        return Swift.min(Swift.max(value, lower), upper)
    }
}
