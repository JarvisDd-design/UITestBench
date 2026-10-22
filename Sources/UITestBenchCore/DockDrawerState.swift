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

    public init(hovered: DockModule? = nil, pinned: DockModule? = nil) {
        self.hovered = hovered
        self.pinned = pinned
    }

    public var presented: DockModule? { pinned ?? hovered }

    public mutating func hover(_ module: DockModule) {
        guard pinned == nil else { return }
        hovered = module
    }

    public mutating func unhover(_ module: DockModule) {
        guard hovered == module else { return }
        hovered = nil
    }

    public mutating func pin(_ module: DockModule) {
        pinned = pinned == module ? nil : module
        hovered = nil
    }

    /// 悬停计时到点时只清 hover，不能碰钉住状态。
    public mutating func clearHover() {
        hovered = nil
    }

    public mutating func dismiss() {
        pinned = nil
        hovered = nil
    }
}
