import AppKit
import CoreGraphics
import Darwin
import Foundation

public struct RawDisplaySnapshot: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let uuid: String
    public let name: String?
    public let isBuiltin: Bool
    public let isActive: Bool
    public let isOnline: Bool
    public let originX: Int
    public let originY: Int
    public let width: Int
    public let height: Int
    public let isMain: Bool

    public init(
        id: CGDirectDisplayID,
        uuid: String,
        name: String?,
        isBuiltin: Bool,
        isActive: Bool,
        isOnline: Bool,
        originX: Int = 0,
        originY: Int = 0,
        width: Int,
        height: Int,
        isMain: Bool = false
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.isOnline = isOnline
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.isMain = isMain
    }
}

public struct DisplayOriginUpdate: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let x: Int32
    public let y: Int32

    public init(displayID: CGDirectDisplayID, x: Int32, y: Int32) {
        self.displayID = displayID
        self.x = x
        self.y = y
    }
}

public protocol DisplayBackend: AnyObject {
    var isPrivateAPIAvailable: Bool { get }
    func fetchDisplays() -> [RawDisplaySnapshot]
    func setDisplayEnabled(
        _ displayID: CGDirectDisplayID,
        enabled: Bool,
        option: CGConfigureOption
    ) throws
    func applyLayout(
        _ updates: [DisplayOriginUpdate],
        option: CGConfigureOption
    ) throws
    func startObservingReconfiguration(_ handler: @escaping @Sendable () -> Void)
    func stopObservingReconfiguration()
}

private typealias CGSConfigureDisplayEnabledFunc = @convention(c) (
    CGDisplayConfigRef,
    CGDirectDisplayID,
    Bool
) -> CGError

private typealias CoreDisplayCreateInfoDictionaryFunc = @convention(c) (
    CGDirectDisplayID
) -> Unmanaged<CFDictionary>?

private final class ReconfigurationBox: @unchecked Sendable {
    let lock = NSLock()
    var handler: (@Sendable () -> Void)?

    func invoke() {
        lock.lock()
        let current = handler
        lock.unlock()
        current?()
    }
}

private let sharedReconfigurationBox = ReconfigurationBox()

private let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    if !flags.contains(.beginConfigurationFlag) {
        sharedReconfigurationBox.invoke()
    }
}

public final class CoreGraphicsBackend: DisplayBackend {
    private let configureDisplayEnabled: CGSConfigureDisplayEnabledFunc?
    private let createDisplayInfoDictionary: CoreDisplayCreateInfoDictionaryFunc?
    private var loadedHandles: [UnsafeMutableRawPointer] = []
    private var isObserving = false

    public var isPrivateAPIAvailable: Bool {
        configureDisplayEnabled != nil
    }

    public init() {
        var handles: [UnsafeMutableRawPointer] = []

        func loadSymbol<T>(
            names: [String],
            frameworkPaths: [String],
            as type: T.Type
        ) -> T? {
            for path in frameworkPaths {
                if let handle = dlopen(path, RTLD_LAZY) {
                    handles.append(handle)
                    for name in names {
                        if let sym = dlsym(handle, name) {
                            return unsafeBitCast(sym, to: type)
                        }
                    }
                }
            }
            for name in names {
                if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                    return unsafeBitCast(sym, to: type)
                }
            }
            return nil
        }

        self.configureDisplayEnabled = loadSymbol(
            names: ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"],
            frameworkPaths: [
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
            ],
            as: CGSConfigureDisplayEnabledFunc.self
        )

        self.createDisplayInfoDictionary = loadSymbol(
            names: ["CoreDisplay_DisplayCreateInfoDictionary"],
            frameworkPaths: [
                "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
            ],
            as: CoreDisplayCreateInfoDictionaryFunc.self
        )

        self.loadedHandles = handles
    }

    deinit {
        stopObservingReconfiguration()
        for handle in loadedHandles {
            dlclose(handle)
        }
    }

    public func fetchDisplays() -> [RawDisplaySnapshot] {
        let maxDisplays: UInt32 = 32
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(maxDisplays, &onlineIDs, &onlineCount)

        var activeIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(maxDisplays, &activeIDs, &activeCount)

        let activeSet = Set(activeIDs.prefix(Int(activeCount)))
        var allIDs = Array(onlineIDs.prefix(Int(onlineCount)))
        for id in activeSet where !allIDs.contains(id) {
            allIDs.append(id)
        }

        let mainID = CGMainDisplayID()
        let screenNames = activeScreenNames()

        return allIDs.map { id in
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let isActive = activeSet.contains(id) || CGDisplayIsActive(id) != 0
            let isOnline = CGDisplayIsOnline(id) != 0
            let uuid = displayUUIDString(for: id)
            let name = screenNames[id] ?? coreDisplayName(for: id)

            // CGDisplayBounds 返回逻辑点坐标与尺寸，与 CGConfigureDisplayOrigin 单位一致
            let bounds = CGDisplayBounds(id)
            let originX = Int(bounds.origin.x.rounded())
            let originY = Int(bounds.origin.y.rounded())
            let width: Int
            let height: Int
            if bounds.width > 0, bounds.height > 0 {
                width = Int(bounds.width.rounded())
                height = Int(bounds.height.rounded())
            } else if let mode = CGDisplayCopyDisplayMode(id) {
                width = mode.width
                height = mode.height
            } else {
                width = CGDisplayPixelsWide(id)
                height = CGDisplayPixelsHigh(id)
            }

            return RawDisplaySnapshot(
                id: id,
                uuid: uuid,
                name: name,
                isBuiltin: isBuiltin,
                isActive: isActive,
                isOnline: isOnline,
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                isMain: isActive && (id == mainID || (originX == 0 && originY == 0))
            )
        }
    }

    public func setDisplayEnabled(
        _ displayID: CGDirectDisplayID,
        enabled: Bool,
        option: CGConfigureOption
    ) throws {
        guard let configureDisplayEnabled else {
            throw MonitorBlockError.privateAPINotAvailable
        }

        var configRef: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        guard beginErr == .success, let config = configRef else {
            throw MonitorBlockError.configurationFailed(beginErr.rawValue)
        }

        let setErr = configureDisplayEnabled(config, displayID, enabled)
        guard setErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw MonitorBlockError.configurationFailed(setErr.rawValue)
        }

        let completeErr = CGCompleteDisplayConfiguration(config, option)
        guard completeErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw MonitorBlockError.configurationFailed(completeErr.rawValue)
        }
    }

    public func applyLayout(
        _ updates: [DisplayOriginUpdate],
        option: CGConfigureOption
    ) throws {
        guard !updates.isEmpty else { return }

        var configRef: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        guard beginErr == .success, let config = configRef else {
            throw MonitorBlockError.configurationFailed(beginErr.rawValue)
        }

        for update in updates {
            let err = CGConfigureDisplayOrigin(config, update.displayID, update.x, update.y)
            guard err == .success else {
                CGCancelDisplayConfiguration(config)
                throw MonitorBlockError.configurationFailed(err.rawValue)
            }
        }

        let completeErr = CGCompleteDisplayConfiguration(config, option)
        guard completeErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw MonitorBlockError.configurationFailed(completeErr.rawValue)
        }
    }

    public func startObservingReconfiguration(_ handler: @escaping @Sendable () -> Void) {
        sharedReconfigurationBox.lock.lock()
        sharedReconfigurationBox.handler = handler
        sharedReconfigurationBox.lock.unlock()

        if !isObserving {
            CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
            isObserving = true
        }
    }

    public func stopObservingReconfiguration() {
        if isObserving {
            CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, nil)
            isObserving = false
        }
        sharedReconfigurationBox.lock.lock()
        sharedReconfigurationBox.handler = nil
        sharedReconfigurationBox.lock.unlock()
    }

    private func displayUUIDString(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, cfUUID) as String? {
            return str
        }
        return "display-\(displayID)"
    }

    private func activeScreenNames() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[key] as? NSNumber {
                result[CGDirectDisplayID(num.uint32Value)] = screen.localizedName
            }
        }
        return result
    }

    private func coreDisplayName(for displayID: CGDirectDisplayID) -> String? {
        guard let createDisplayInfoDictionary,
              let info = createDisplayInfoDictionary(displayID)?.takeRetainedValue() as? [String: Any],
              let names = info["DisplayProductName"] as? [String: String],
              !names.isEmpty else {
            return nil
        }

        if let preferred = Locale.preferredLanguages.first,
           let exact = names[preferred] {
            return exact
        }
        if let en = names["en_US"] {
            return en
        }
        return names.values.first
    }
}
