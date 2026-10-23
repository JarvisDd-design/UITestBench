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

    /// 点在这个窗口里要不要收起抽屉。
    ///
    /// sheet（比如「关于」）是挂在抽屉上的独立窗口，里面的点击坐标是 sheet 自己的，
    /// 不能拿来和坞宽比较，否则点 sheet 右半边就会把抽屉连同 sheet 一起关掉。
    /// 应用级模态（比如「选择本地文件…」的 NSOpenPanel）同理。
    public func shouldDismissOnClick(
        atX x: CGFloat,
        dockWidth: CGFloat,
        isSheet: Bool,
        isModal: Bool = false
    ) -> Bool {
        guard pinned != nil, !isSheet, !isModal else { return false }
        return x > dockWidth
    }
}
