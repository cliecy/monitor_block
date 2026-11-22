import AppKit
import CoreGraphics
import MonitorBlockCore
import SwiftUI

// MARK: - Shared Visual Building Blocks

struct PillTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .cornerRadius(5)
    }
}

struct StatusBannerView: View {
    let text: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .orange : .accentColor)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background((isError ? Color.orange : Color.accentColor).opacity(0.13))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((isError ? Color.orange : Color.accentColor).opacity(0.28), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

struct SurfaceCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

func volumeSymbolName(level: Double, muted: Bool) -> String {
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

// MARK: - Display Role Segmented Control (Main / Extended / Mirrored)

struct DisplayModeSegmentedControl: View {
    let display: DisplayInfo
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let masters = viewModel.availableMirrorMasters(for: display)
        let isMain = (display.usageMode == .main)
        let isExtended = (display.usageMode == .extended)
        let mirrorLabel: String = {
            if case .mirrored(_, _, let masterName) = display.usageMode {
                return "镜像「\(masterName)」"
            }
            return masters.count > 1 ? "镜像 ▾" : "镜像"
        }()

        HStack(spacing: 4) {
            // 1. 主屏幕
            modeButton(
                title: "主屏幕",
                icon: "star.fill",
                isActive: isMain,
                activeColor: .accentColor
            ) {
                viewModel.setDisplayAsMain(display)
            }

            // 2. 拓展显示器
            modeButton(
                title: "拓展",
                icon: "rectangle.split.2x1",
                isActive: isExtended,
                activeColor: .blue
            ) {
                viewModel.setDisplayAsExtended(display)
            }

            // 3. 镜像屏幕（2 屏一键直切；多屏弹出源屏幕选择菜单）
            if masters.isEmpty {
                modeButton(
                    title: "镜像",
                    icon: "rectangle.on.rectangle",
                    isActive: display.usageMode.isMirrored,
                    activeColor: .purple
                ) {}
                .disabled(true)
            } else if masters.count == 1, let onlyMaster = masters.first {
                modeButton(
                    title: mirrorLabel,
                    icon: "rectangle.on.rectangle",
                    isActive: display.usageMode.isMirrored,
                    activeColor: .purple
                ) {
                    viewModel.setDisplayAsMirror(display, master: onlyMaster)
                }
            } else {
                Menu {
                    Text("选择要镜像的源屏幕")
                    Divider()
                    ForEach(masters) { master in
                        let isCurrentMaster = (display.mirrorMasterID == master.id)
                        Button {
                            viewModel.setDisplayAsMirror(display, master: master)
                        } label: {
                            if isCurrentMaster {
                                Text("✓ 镜像「\(master.name)」")
                            } else {
                                Text("镜像「\(master.name)」")
                            }
                        }
                    }
                    if display.usageMode.isMirrored {
                        Divider()
                        Button("取消镜像（恢复为拓展）") {
                            viewModel.setDisplayAsExtended(display)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(mirrorLabel)
                            .font(.system(size: 11, weight: display.usageMode.isMirrored ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 27)
                    .foregroundColor(display.usageMode.isMirrored ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(display.usageMode.isMirrored ? Color.purple : Color.primary.opacity(0.06))
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
    }

    private func modeButton(
        title: String,
        icon: String,
        isActive: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            .foregroundColor(isActive ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? activeColor : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Input Source Control Strip (with Hardware Readback & Calibration)

struct InputSourceControlStrip: View {
    let displayUUID: String
    let endpointIndex: Int
    let displayName: String
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let status = viewModel.inputStatuses[endpointIndex]
        let activeSource = status?.activeSource
        let switchingTarget = viewModel.switchingInputs[endpointIndex]

        HStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(DisplayInputSource.allCases) { source in
                    let isSelected = (switchingTarget == source) || (switchingTarget == nil && activeSource == source)
                    let isSwitchingThis = (switchingTarget == source)
                    let isCalibrated = (status?.calibratedCodes[source] != nil)

                    Button {
                        viewModel.switchInputSource(source, endpointIndex: endpointIndex, displayName: displayName)
                    } label: {
                        HStack(spacing: 3) {
                            if isSwitchingThis {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                            }
                            Text(source.label)
                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                            if isCalibrated && !isSwitchingThis {
                                Circle()
                                    .fill(isSelected ? Color.white : Color.teal)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .foregroundColor(isSelected ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.055))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(switchingTarget != nil)
                }
            }

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

                if viewModel.ddcEndpoints.count > 1 {
                    Menu("DDC 硬件通道（通道 #\(endpointIndex + 1)）") {
                        ForEach(viewModel.ddcEndpoints) { ep in
                            let serialHint = ep.serialNumber.map { " · SN:\($0.suffix(4))" } ?? ""
                            let label = "通道 #\(ep.index + 1) \(ep.name)\(serialHint)"
                            Button {
                                viewModel.bindDisplay(displayUUID, toDDCEndpoint: ep)
                            } label: {
                                if ep.index == endpointIndex {
                                    Text("✓ \(label)")
                                } else {
                                    Text(label)
                                }
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
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(5.5)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("查看硬件输入码、校准 USB-C 等端口编码或切换协议模式")
        }
    }
}

// MARK: - Unified Display Control Card (Compact Popover + Expanded Desktop Mode)

struct DisplayControlCard: View {
    let display: DisplayInfo
    let showInlineRename: Bool
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let ddcIndex = viewModel.displayToDDCIndex[display.uuid]
        let isEnabled = display.isEnabledForDisplay

        SurfaceCard {
            VStack(alignment: .leading, spacing: isEnabled ? 10 : 0) {
                // Header Row: Icon + Name + Role Badge + Resolution + Power Toggle
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accentColorForMode.opacity(isEnabled ? 0.16 : 0.08))
                            .frame(width: 34, height: 34)
                        Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(isEnabled ? accentColorForMode : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(display.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                            PillTag(text: display.usageMode.shortLabel, color: accentColorForMode)
                            if display.isBuiltin {
                                PillTag(text: "内置", color: .secondary)
                            }
                            if viewModel.hasDisableRule(for: display.uuid) {
                                PillTag(text: "规则", color: .indigo)
                            }
                        }

                        HStack(spacing: 6) {
                            if let res = display.resolutionText {
                                Text(res)
                            }
                            if case .mirrored(_, _, let masterName) = display.usageMode {
                                Text("· 镜像「\(masterName)」")
                                    .foregroundColor(.purple)
                            } else if isEnabled, let idx = ddcIndex,
                                      let activeSrc = viewModel.inputStatuses[idx]?.activeSource {
                                Text("· 当前 \(activeSrc.label)")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    if showInlineRename && isEnabled {
                        Button {
                            viewModel.identifyDisplays(onlyUUID: display.uuid)
                        } label: {
                            Image(systemName: "sparkles.tv")
                                .font(.system(size: 12))
                                .frame(width: 26, height: 26)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("在此屏幕中央闪显识别名称")
                    }

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isEnabled },
                            set: { viewModel.setDisplay(display, enabled: $0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }

                if isEnabled {
                    // Role Switcher: Main / Extended / Mirror
                    DisplayModeSegmentedControl(display: display, viewModel: viewModel)

                    // Input Source Strip (for DDC-capable external monitors)
                    if let idx = ddcIndex {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("信号输入源")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.secondary)
                            InputSourceControlStrip(
                                displayUUID: display.uuid,
                                endpointIndex: idx,
                                displayName: display.name,
                                viewModel: viewModel
                            )
                        }
                    }

                    // Inline Rename (Desktop App Window only)
                    if showInlineRename {
                        Divider()
                        HStack(spacing: 8) {
                            Text("自定义名称")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            TextField(
                                "例如：左 LG / 右 LG",
                                text: Binding(
                                    get: { viewModel.renameDrafts[display.uuid] ?? display.name },
                                    set: { viewModel.renameDrafts[display.uuid] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                            Button("保存") {
                                viewModel.saveCustomName(for: display.uuid)
                            }
                            .controlSize(.small)

                            if display.customName != nil {
                                Button("恢复默认") {
                                    viewModel.resetCustomName(for: display.uuid)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private var accentColorForMode: Color {
        switch display.usageMode {
        case .main: return .accentColor
        case .extended: return .blue
        case .mirrored: return .purple
        case .disabled: return .secondary
        }
    }
}

// MARK: - Mini Topology Preview (Read-only Preview for Popover Layout Tab)

struct MiniLayoutPreviewView: View {
    let placements: [DisplayPlacement]
    let mirroredDisplays: [DisplayInfo]

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let transform = computeTransform(canvasSize: geo.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        )

                    if placements.isEmpty {
                        Text("暂无活跃独立显示器")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(placements) { item in
                            let rect = CGRect(
                                x: transform.offsetX + CGFloat(item.x) * transform.scale,
                                y: transform.offsetY + CGFloat(item.y) * transform.scale,
                                width: max(CGFloat(item.width) * transform.scale, 52),
                                height: max(CGFloat(item.height) * transform.scale, 34)
                            )
                            ZStack(alignment: .top) {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(item.isMain ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.14))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(item.isMain ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: item.isMain ? 1.5 : 1)
                                    )
                                if item.isMain {
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(height: 4)
                                        .cornerRadius(2)
                                        .padding(.horizontal, 3)
                                        .padding(.top, 2)
                                }
                                VStack(spacing: 1) {
                                    Spacer(minLength: 6)
                                    Text(item.name)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .lineLimit(1)
                                    Text(item.isMain ? "主屏" : "拓展")
                                        .font(.system(size: 8))
                                        .foregroundColor(item.isMain ? .accentColor : .secondary)
                                    Spacer(minLength: 2)
                                }
                                .padding(.horizontal, 4)
                            }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
            }
            .frame(height: 118)

            if !mirroredDisplays.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 10))
                        .foregroundColor(.purple)
                    let summary = mirroredDisplays.map { d -> String in
                        if case .mirrored(_, _, let master) = d.usageMode {
                            return "\(d.name) → \(master)"
                        }
                        return d.name
                    }.joined(separator: " · ")
                    Text("镜像中：\(summary)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.purple)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    private func computeTransform(canvasSize: CGSize) -> (scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        guard !placements.isEmpty else { return (0.04, canvasSize.width / 2, canvasSize.height / 2) }
        let minX = placements.map(\.x).min() ?? 0
        let minY = placements.map(\.y).min() ?? 0
        let maxX = placements.map { $0.x + $0.width }.max() ?? 1920
        let maxY = placements.map { $0.y + $0.height }.max() ?? 1080

        let contentW = CGFloat(max(maxX - minX, 800))
        let contentH = CGFloat(max(maxY - minY, 600))
        let pad: CGFloat = 18
        let usableW = max(canvasSize.width - pad * 2, 80)
        let usableH = max(canvasSize.height - pad * 2, 60)

        let scale = min(usableW / contentW, usableH / contentH, 0.065)
        let offsetX = (canvasSize.width - contentW * scale) / 2 - CGFloat(minX) * scale
        let offsetY = (canvasSize.height - contentH * scale) / 2 - CGFloat(minY) * scale
        return (scale, offsetX, offsetY)
    }
}

// MARK: - Interactive Arrangement Canvas (Drag + Edge Snapping)

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
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )

                ForEach(placements) { item in
                    let rect = CGRect(
                        x: transform.offsetX + CGFloat(item.x) * transform.scale,
                        y: transform.offsetY + CGFloat(item.y) * transform.scale,
                        width: max(CGFloat(item.width) * transform.scale, 70),
                        height: max(CGFloat(item.height) * transform.scale, 48)
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
                                        placements = AppViewModel.normalized(placements)
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
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: isSelected ? 2 : 1)
                )

            if item.isMain {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, 5)
                    .padding(.top, 3)
            }

            VStack(spacing: 2) {
                Spacer(minLength: 9)
                Text(item.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(item.width)×\(item.height)")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                if item.isMain {
                    Text("主屏幕")
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

    private func snapDisplay(at index: Int) {
        guard placements.count > 1 else { return }
        let moving = placements[index]
        let others = placements.enumerated().filter { $0.offset != index }.map(\.element)

        var bestX = moving.x
        var bestY = moving.y
        var bestDistance = Double.greatestFiniteMagnitude

        for other in others {
            let candidates: [(Int, Int)] = [
                (other.x - moving.width, clamp(moving.y, min: other.y - moving.height + 120, max: other.y + other.height - 120)),
                (other.x + other.width, clamp(moving.y, min: other.y - moving.height + 120, max: other.y + other.height - 120)),
                (clamp(moving.x, min: other.x - moving.width + 120, max: other.x + other.width - 120), other.y - moving.height),
                (clamp(moving.x, min: other.x - moving.width + 120, max: other.x + other.width - 120), other.y + other.height)
            ]

            for (cx, cy) in candidates {
                let dist = hypot(Double(cx - moving.x), Double(cy - moving.y))
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
