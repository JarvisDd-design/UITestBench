import Foundation

public enum DockModule: String, CaseIterable, Equatable, Sendable {
    case material
    case device
    case app
    case diagnostics
    case settings
}

/// 多面板下，一次点击落在哪个窗口里。
public enum DockClickTarget: Equatable, Sendable {
    case dock
    case drawer
    case phone
    /// 扫码浮层、底胶囊等辅助面板。
    case auxiliary
    case sheet
    case modal
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

    /// 多面板版本：只有点手机才收起钉住的抽屉。
    /// 钉住之外的 hover 抽屉本来就会自己收起，点击不需要干预。
    public func shouldDismissOnClick(target: DockClickTarget) -> Bool {
        guard pinned != nil else { return false }
        return target == .phone
    }

}

/// 抽屉打开时按下 Esc 该做什么。
public enum DockEscapeAction: Equatable, Sendable {
    /// 不归抽屉管，事件照常往下传。
    case ignore
    /// 先把输入焦点交出去，抽屉保持打开。
    case endEditing
    /// 收起抽屉。
    case dismiss
}

/// 抽屉的 Esc 判定。
///
/// 抽屉多半没有焦点（hover 打开、`becomesKeyOnlyIfNeeded`），
/// 所以判定不能依赖抽屉自己的 `onExitCommand`；由 App 层的键盘监视器
/// 按「当前 key 窗口是谁」决定，再把事件吞掉或放行。
public enum DockEscapePolicy {
    /// - Parameters:
    ///   - isPresented: 当前是否有抽屉（hover 或钉住）可见。
    ///   - isEditingText: key 窗口的 first responder 是否是输入框的 field editor。
    ///   - hasForeignKeyWindow: key 窗口属于别的用途（扫码浮层、sheet、模态）。
    public static func action(
        isPresented: Bool,
        isEditingText: Bool,
        hasForeignKeyWindow: Bool
    ) -> DockEscapeAction {
        guard isPresented, !hasForeignKeyWindow else { return .ignore }
        return isEditingText ? .endEditing : .dismiss
    }
}
