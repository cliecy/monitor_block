import CoreGraphics
import Foundation

public struct DisplayInfo: Equatable, Identifiable, Sendable {
    public let id: CGDirectDisplayID
    public let uuid: String
    public let name: String
    public let systemName: String
    public let customName: String?
    public let isBuiltin: Bool
    public let isActive: Bool
    public let isOnline: Bool
    public let originX: Int
    public let originY: Int
    public let width: Int
    public let height: Int
    public let isMain: Bool
    public let disabledByApp: Bool

    public init(
        id: CGDirectDisplayID,
        uuid: String,
        name: String,
        systemName: String? = nil,
        customName: String? = nil,
        isBuiltin: Bool,
        isActive: Bool,
        isOnline: Bool,
        originX: Int = 0,
        originY: Int = 0,
        width: Int,
        height: Int,
        isMain: Bool = false,
        disabledByApp: Bool = false
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.systemName = systemName ?? name
        self.customName = customName
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.isOnline = isOnline
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.isMain = isMain
        self.disabledByApp = disabledByApp
    }

    public var resolutionText: String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }
}

/// 单个显示器在逻辑坐标系中的位置与尺寸（以 UUID 作为跨重启稳定标识）
public struct DisplayPlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public var name: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var isMain: Bool

    public init(
        uuid: String,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        isMain: Bool
    ) {
        self.uuid = uuid
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isMain = isMain
    }
}

/// 可复用的命名布局预设
public struct LayoutPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var placements: [DisplayPlacement]

    public init(id: UUID = UUID(), name: String, placements: [DisplayPlacement]) {
        self.id = id
        self.name = name
        self.placements = placements
    }
}

/// 关闭某块外接显示器后自动应用的布局规则
public struct DisableLayoutRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { targetDisplayUUID }
    public let targetDisplayUUID: String
    public var targetDisplayName: String
    public var layoutOnDisable: [DisplayPlacement]
    public var restorePreviousOnEnable: Bool

    public init(
        targetDisplayUUID: String,
        targetDisplayName: String,
        layoutOnDisable: [DisplayPlacement],
        restorePreviousOnEnable: Bool = true
    ) {
        self.targetDisplayUUID = targetDisplayUUID
        self.targetDisplayName = targetDisplayName
        self.layoutOnDisable = layoutOnDisable
        self.restorePreviousOnEnable = restorePreviousOnEnable
    }
}

public enum MonitorBlockError: Error, LocalizedError, Equatable, Sendable {
    case privateAPINotAvailable
    case displayNotFound(CGDirectDisplayID)
    case displayUUIDNotFound(String)
    case cannotDisableLastActiveDisplay
    case cannotDisableBuiltinDisplay
    case presetNotFound(UUID)
    case noMatchingActiveDisplaysForLayout
    case configurationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .privateAPINotAvailable:
            return "当前 macOS 系统不支持 CGSConfigureDisplayEnabled 私有显示控制接口，无法软断开外接显示器。"
        case .displayNotFound(let id):
            return "未找到指定的显示器（ID: \(id)），可能已被拔出。"
        case .displayUUIDNotFound(let uuid):
            return "未找到指定的活跃显示器（UUID: \(uuid)）。"
        case .cannotDisableLastActiveDisplay:
            return "无法停用最后一块活跃屏幕，已自动拦截以防止全黑锁死。"
        case .cannotDisableBuiltinDisplay:
            return "为防止误操作，当前不允许停用内置显示器。"
        case .presetNotFound:
            return "未找到指定的布局预设。"
        case .noMatchingActiveDisplaysForLayout:
            return "当前没有与该布局匹配的活跃显示器。"
        case .configurationFailed(let code):
            return "修改显示器配置失败（CoreGraphics 错误码: \(code)）。"
        }
    }
}
