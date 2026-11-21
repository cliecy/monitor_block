import CoreGraphics
import Foundation

public struct CachedDisplayRecord: Codable, Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let uuid: String
    public var name: String
    public var width: Int
    public var height: Int
    public var disabledByApp: Bool

    public init(
        id: CGDirectDisplayID,
        uuid: String,
        name: String,
        width: Int,
        height: Int,
        disabledByApp: Bool
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.width = width
        self.height = height
        self.disabledByApp = disabledByApp
    }
}

public struct PersistedAppState: Codable, Equatable, Sendable {
    public var cachedDisplays: [CachedDisplayRecord]
    public var presets: [LayoutPreset]
    public var disableRules: [String: DisableLayoutRule]
    public var preDisableSnapshots: [String: [DisplayPlacement]]

    public init(
        cachedDisplays: [CachedDisplayRecord] = [],
        presets: [LayoutPreset] = [],
        disableRules: [String: DisableLayoutRule] = [:],
        preDisableSnapshots: [String: [DisplayPlacement]] = [:]
    ) {
        self.cachedDisplays = cachedDisplays
        self.presets = presets
        self.disableRules = disableRules
        self.preDisableSnapshots = preDisableSnapshots
    }
}

public protocol StateStoreProtocol: AnyObject {
    func loadState() -> PersistedAppState
    func saveState(_ state: PersistedAppState)
}

public final class FileStateStore: StateStoreProtocol {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = appSupport
                .appendingPathComponent("MonitorBlock", isDirectory: true)
                .appendingPathComponent("state.json")
        }
    }

    public func loadState() -> PersistedAppState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return PersistedAppState()
        }
        if let state = try? JSONDecoder().decode(PersistedAppState.self, from: data) {
            return state
        }
        // 兼容旧版本仅保存 [CachedDisplayRecord] 的 state.json
        if let legacy = try? JSONDecoder().decode([CachedDisplayRecord].self, from: data) {
            return PersistedAppState(cachedDisplays: legacy)
        }
        return PersistedAppState()
    }

    public func saveState(_ state: PersistedAppState) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

public final class InMemoryStateStore: StateStoreProtocol {
    private var state: PersistedAppState

    public init(initial: PersistedAppState = PersistedAppState()) {
        self.state = initial
    }

    public func loadState() -> PersistedAppState {
        state
    }

    public func saveState(_ state: PersistedAppState) {
        self.state = state
    }
}
