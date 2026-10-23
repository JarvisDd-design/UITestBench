import CoreGraphics

/// 手机周围三块悬浮面板的间距与安全边距（pt）。
public struct FloatingPanelMetrics: Equatable, Sendable {
    public var dockGap: CGFloat
    public var capsuleGap: CGFloat
    public var drawerGap: CGFloat
    /// 面板被夹进可见屏幕时与屏幕边缘保留的距离。
    public var screenInset: CGFloat

    public init(
        dockGap: CGFloat = 12,
        capsuleGap: CGFloat = 12,
        drawerGap: CGFloat = 12,
        screenInset: CGFloat = 8
    ) {
        self.dockGap = dockGap
        self.capsuleGap = capsuleGap
        self.drawerGap = drawerGap
        self.screenInset = screenInset
    }

    public static let standard = FloatingPanelMetrics()
}

/// 可见面板的屏幕坐标（AppKit 左下原点）。不含面板四周给阴影留的 padding。
public struct FloatingPanelFrames: Equatable, Sendable {
    public let dock: CGRect
    public let capsule: CGRect
    public let drawer: CGRect?

    public init(dock: CGRect, capsule: CGRect, drawer: CGRect?) {
        self.dock = dock
        self.capsule = capsule
        self.drawer = drawer
    }
}

public enum FloatingPanelLayoutCalculator {
    /// 坞顶对齐手机顶边、底胶囊贴手机下方、抽屉在坞左侧并尽量垂直居中。
    /// 抽屉只夹边、不翻到右边：屏幕左侧不够时压住坞是允许的。
    public static func frames(
        phoneFrame: CGRect,
        dockSize: CGSize,
        capsuleHeight: CGFloat,
        drawerSize: CGSize?,
        visibleScreen: CGRect,
        metrics: FloatingPanelMetrics = .standard
    ) -> FloatingPanelFrames {
        let dockWidth = max(0, dockSize.width)
        let dockHeight = max(0, dockSize.height)
        let dock = CGRect(
            x: phoneFrame.minX - metrics.dockGap - dockWidth,
            y: phoneFrame.maxY - dockHeight,
            width: dockWidth,
            height: dockHeight
        )

        let capsule = CGRect(
            x: phoneFrame.minX,
            y: phoneFrame.minY - metrics.capsuleGap - max(0, capsuleHeight),
            width: max(0, phoneFrame.width),
            height: max(0, capsuleHeight)
        )

        return FloatingPanelFrames(
            dock: dock,
            capsule: capsule,
            drawer: drawerFrame(
                drawerSize: drawerSize,
                dock: dock,
                visibleScreen: visibleScreen,
                metrics: metrics
            )
        )
    }

    /// 把手机窗口夹进可见屏幕，同时给左侧坞和下方胶囊留出位置。
    ///
    /// 屏幕窄/矮到安全区放不下时，优先让手机自己留在屏幕里（此时坞或胶囊
    /// 可能被挤出屏幕）；手机尺寸应该先由 `PhoneLayoutCalculator.maximumScreenWidth`
    /// 限住，正常不会走到这个分支。
    public static func clampedPhoneFrame(
        _ phoneFrame: CGRect,
        dockWidth: CGFloat,
        capsuleHeight: CGFloat,
        visibleScreen: CGRect,
        metrics: FloatingPanelMetrics = .standard
    ) -> CGRect {
        let minX = visibleScreen.minX + metrics.dockGap + max(0, dockWidth) + metrics.screenInset
        let maxX = visibleScreen.maxX - metrics.screenInset - phoneFrame.width
        let x: CGFloat
        if maxX < minX {
            x = maxX
        } else {
            x = min(max(phoneFrame.minX, minX), maxX)
        }

        let minY = visibleScreen.minY + metrics.capsuleGap + max(0, capsuleHeight) + metrics.screenInset
        let maxY = visibleScreen.maxY - metrics.screenInset - phoneFrame.height
        let y: CGFloat
        if maxY < minY {
            y = maxY
        } else {
            y = min(max(phoneFrame.minY, minY), maxY)
        }

        return CGRect(x: x, y: y, width: phoneFrame.width, height: phoneFrame.height)
    }

    private static func drawerFrame(
        drawerSize: CGSize?,
        dock: CGRect,
        visibleScreen: CGRect,
        metrics: FloatingPanelMetrics
    ) -> CGRect? {
        guard let drawerSize, drawerSize.width > 0, drawerSize.height > 0 else {
            return nil
        }

        let width = drawerSize.width
        let height = drawerSize.height

        let minX = visibleScreen.minX + metrics.screenInset
        let x = max(minX, dock.minX - metrics.drawerGap - width)

        let minY = visibleScreen.minY + metrics.screenInset
        let maxY = visibleScreen.maxY - metrics.screenInset - height
        let centered = dock.midY - height / 2
        // 放不下时贴住可见区顶部，保证标题栏（而不是底部）先露出来。
        let y = maxY < minY ? maxY : min(max(centered, minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}
