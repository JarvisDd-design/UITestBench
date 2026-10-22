import Foundation

public enum DockModule: String, CaseIterable, Equatable, Sendable {
    case material
    case device
    case app
    case diagnostics
    case settings
}

/// 坞的展示规则：钉住的优先于 hover 的，同一时间只有一个抽屉。
public struct DockDrawerState: Equatable, Sendable {
    public private(set) var hovered: DockModule?
    public private(set) var pinned: DockModule?

    public init() {}

    public var presented: DockModule? { pinned ?? hovered }

    public mutating func hover(_ module: DockModule) {
        guard pinned == nil else { return }
        hovered = module
    }

    public mutating func unhover(_ module: DockModule) {
        guard hovered == module else { return }
        hovered = nil
    }

    /// 同一模块再点一次取消钉住；点别的模块直接换抽屉。
    public mutating func pin(_ module: DockModule) {
        pinned = pinned == module ? nil : module
        hovered = nil
    }

    /// 只在整体收起时用；按模块的收起计时请用 `unhover(_:)`，避免误关别的抽屉。
    public mutating func clearHover() {
        hovered = nil
    }

    public mutating func dismiss() {
        pinned = nil
        hovered = nil
    }
}
