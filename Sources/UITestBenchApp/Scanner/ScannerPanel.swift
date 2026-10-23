import AppKit
import QuartzCore

/// 桌面上那个 320×320 取景区的玻璃卡片。
///
/// 卡片四周是系统毛玻璃（`NSVisualEffectView`），中央取景区完全镂空，
/// 露出下面的飞书/浏览器。毛玻璃只铺在四条边框上，绝不覆盖取景区——
/// 一旦糊住，二维码就识别不了。
final class ScannerPanel: NSPanel {
    enum Phase: Equatable {
        /// 刚出现，给用户时间对准；不识别，光带也不动。
        case preparing
        /// 准备期结束：光带开始扫，识别同时开始。
        case scanning
        /// 命中：停扫，显示成功图标。
        case success
    }

    static let viewfinderSide: CGFloat = 320
    static let cardSize = NSSize(width: 368, height: 452)
    /// 窗口比卡片大一圈，给卡片投影留位置。
    static let shadowMargin: CGFloat = 16
    static let windowSize = NSSize(
        width: cardSize.width + shadowMargin * 2,
        height: cardSize.height + shadowMargin * 2
    )
    static let cornerRadius: CGFloat = 28

    /// 卡片在视图坐标里（顶部原点）。
    static let cardRect = NSRect(
        x: shadowMargin,
        y: shadowMargin,
        width: cardSize.width,
        height: cardSize.height
    )

    /// 取景区：卡片内左右各 24、顶部标题栏 56、底部提示区 76。
    static let viewfinderRect = NSRect(
        x: shadowMargin + 24,
        y: shadowMargin + 56,
        width: viewfinderSide,
        height: viewfinderSide
    )

    var onCancel: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    var hint: String {
        get { frameView.hint }
        set { frameView.hint = newValue }
    }

    var phase: Phase {
        get { frameView.phase }
        set { frameView.phase = newValue }
    }

    /// 取景区在屏幕上的位置（AppKit 左下原点）。捕获只认这一块。
    var captureFrameInScreen: NSRect {
        let rect = Self.viewfinderRect
        let local = NSRect(
            x: rect.minX,
            y: frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        return NSRect(
            x: frame.minX + local.minX,
            y: frame.minY + local.minY,
            width: local.width,
            height: local.height
        )
    }

    private let frameView: ScannerFrameView

    init() {
        let container = ScannerContainerView(frame: NSRect(origin: .zero, size: Self.windowSize))
        let frameView = ScannerFrameView(frame: container.bounds)
        self.frameView = frameView

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none

        container.autoresizingMask = [.width, .height]
        contentView = container

        for piece in Self.glassPieces {
            container.addSubview(Self.makeGlassPiece(piece.rect, corners: piece.corners))
        }

        frameView.autoresizingMask = [.width, .height]
        frameView.onCancel = { [weak self] in self?.onCancel?() }
        frameView.onDragStart = { [weak self] in self?.onDragStart?() }
        frameView.onDragEnd = { [weak self] in self?.onDragEnd?() }
        container.addSubview(frameView)
    }

    /// 工具是二态主题，系统外观不一定跟得上，这里显式设一次。
    func applyTheme(dark: Bool) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func showSuccess(then completion: @escaping () -> Void) {
        frameView.showSuccess(then: completion)
    }

    /// 每次打开都放在鼠标所在屏幕的中央，不记忆上次位置。
    static func centeredOnMouseScreen() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else {
            return NSRect(origin: .zero, size: windowSize)
        }
        let visible = screen.visibleFrame
        return NSRect(
            x: (visible.midX - windowSize.width / 2).rounded(),
            y: (visible.midY - windowSize.height / 2).rounded(),
            width: windowSize.width,
            height: windowSize.height
        )
    }

    // MARK: - 玻璃边框

    /// 四条边框：上、下、左、右。中间取景区留空，不铺任何模糊层。
    private static let glassPieces: [(rect: NSRect, corners: CACornerMask)] = [
        (
            NSRect(
                x: shadowMargin,
                y: shadowMargin,
                width: cardSize.width,
                height: 56
            ),
            [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        ),
        (
            NSRect(
                x: shadowMargin,
                y: shadowMargin + cardSize.height - 76,
                width: cardSize.width,
                height: 76
            ),
            [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        ),
        (
            NSRect(
                x: shadowMargin,
                y: shadowMargin + 56,
                width: 24,
                height: viewfinderSide
            ),
            []
        ),
        (
            NSRect(
                x: shadowMargin + cardSize.width - 24,
                y: shadowMargin + 56,
                width: 24,
                height: viewfinderSide
            ),
            []
        ),
    ]

    private static func makeGlassPiece(_ rect: NSRect, corners: CACornerMask) -> NSView {
        let clip = NSView(frame: rect)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.maskedCorners = corners
        clip.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: clip.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        clip.addSubview(effect)
        return clip
    }
}

/// 翻转坐标的容器，让卡片、取景区、光带都按「顶部原点」计算。
private final class ScannerContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// 卡片上的所有可交互内容：自绘边框、标题、提示、关闭按钮、准星、
/// 扫描光带与成功图标，并处理拖动和 Esc。
private final class ScannerFrameView: NSView {
    var hint = "正在准备…" {
        didSet { needsDisplay = true }
    }

    var phase: ScannerPanel.Phase = .preparing {
        didSet {
            guard phase != oldValue else { return }
            switch phase {
            case .preparing:
                stopBeam()
                successLayer.opacity = 0
            case .scanning:
                successLayer.opacity = 0
                startBeam()
            case .success:
                stopBeam()
            }
            needsDisplay = true
        }
    }

    var onCancel: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private let beamClip = CALayer()
    private let beam = CAGradientLayer()
    private let successLayer = CALayer()

    private var closeRect: NSRect {
        let card = ScannerPanel.cardRect
        return NSRect(x: card.maxX - 24 - 28, y: card.minY + 14, width: 28, height: 28)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        configureShadow()
        configureBeam()
        configureSuccessLayer()
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 创建")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        successLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let card = ScannerPanel.cardRect
        let viewfinder = ScannerPanel.viewfinderRect
        let radius = ScannerPanel.cornerRadius

        let outer = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

        // 玻璃高光只画在卡片边框上。取景区必须保持完全透明，
        // 所以用 even-odd 路径把中间挖掉再裁剪。
        if let highlight = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.18),
            NSColor.white.withAlphaComponent(0.01),
        ]) {
            // 手动拼 CGPath：NSBezierPath.cgPath 要 macOS 14，不能用在 12.3。
            let cutoutPath = CGMutablePath()
            cutoutPath.addRoundedRect(in: card, cornerWidth: radius, cornerHeight: radius)
            cutoutPath.addRoundedRect(in: viewfinder, cornerWidth: 18, cornerHeight: 18)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.addPath(cutoutPath)
            NSGraphicsContext.current?.cgContext.clip(using: .evenOdd)
            highlight.draw(
                in: NSRect(x: card.minX, y: card.minY, width: card.width, height: 88),
                angle: -90
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        outer.lineWidth = 1
        NSColor.white.withAlphaComponent(0.38).setStroke()
        outer.stroke()

        // 取景区的玻璃切口：一圈亮边，让「框」有实体感。
        let inner = NSBezierPath(roundedRect: viewfinder, xRadius: 18, yRadius: 18)
        inner.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        inner.stroke()

        drawCorners(in: viewfinder)
        drawTitle()
        drawHint()
        drawCloseButton()
    }

    private func drawCorners(in rect: NSRect) {
        let frame = rect.insetBy(dx: 10, dy: 10)
        let length: CGFloat = 22
        let path = NSBezierPath()
        path.lineWidth = 3.5
        path.lineCapStyle = .round

        // 视图是翻转过坐标：minY 在上。
        path.move(to: NSPoint(x: frame.minX, y: frame.minY + length))
        path.line(to: NSPoint(x: frame.minX, y: frame.minY))
        path.line(to: NSPoint(x: frame.minX + length, y: frame.minY))

        path.move(to: NSPoint(x: frame.maxX - length, y: frame.minY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.minY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.minY + length))

        path.move(to: NSPoint(x: frame.minX, y: frame.maxY - length))
        path.line(to: NSPoint(x: frame.minX, y: frame.maxY))
        path.line(to: NSPoint(x: frame.minX + length, y: frame.maxY))

        path.move(to: NSPoint(x: frame.maxX - length, y: frame.maxY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.maxY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.maxY - length))

        Self.scanBlue.setStroke()
        path.stroke()
    }

    private func drawTitle() {
        let card = ScannerPanel.cardRect
        let text = "扫描二维码" as NSString
        text.draw(
            at: NSPoint(x: card.minX + 24, y: card.minY + 20),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            ]
        )
    }

    private func drawHint() {
        guard !hint.isEmpty else { return }

        let card = ScannerPanel.cardRect
        let text = hint as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = NSSize(width: 14, height: 8)
        let maxWidth = card.width - 48
        let pillWidth = min(ceil(textSize.width) + padding.width * 2, maxWidth)
        let pillHeight = ceil(textSize.height) + padding.height * 2
        let pill = NSRect(
            x: card.midX - pillWidth / 2,
            y: card.maxY - 76 + (76 - pillHeight) / 2,
            width: pillWidth,
            height: pillHeight
        )

        let background = NSBezierPath(
            roundedRect: pill,
            xRadius: pill.height / 2,
            yRadius: pill.height / 2
        )
        NSColor.black.withAlphaComponent(0.45).setFill()
        background.fill()

        let textRect = NSRect(
            x: pill.minX + padding.width,
            y: pill.minY + padding.height,
            width: max(0, pillWidth - padding.width * 2),
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private func drawCloseButton() {
        let rect = closeRect
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: rect).fill()

        let cross = rect.insetBy(dx: 9, dy: 9)
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: cross.minX, y: cross.minY))
        path.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
        path.move(to: NSPoint(x: cross.maxX, y: cross.minY))
        path.line(to: NSPoint(x: cross.minX, y: cross.maxY))
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    // MARK: - 光带与成功图标

    private func configureShadow() {
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 12
        layer?.shadowOffset = .zero
        layer?.shadowPath = CGPath(
            roundedRect: ScannerPanel.cardRect,
            cornerWidth: ScannerPanel.cornerRadius,
            cornerHeight: ScannerPanel.cornerRadius,
            transform: nil
        )
    }

    private func configureBeam() {
        beamClip.frame = ScannerPanel.viewfinderRect
        beamClip.masksToBounds = true
        beamClip.backgroundColor = NSColor.clear.cgColor

        beam.frame = CGRect(
            x: 0,
            y: -90,
            width: ScannerPanel.viewfinderRect.width,
            height: 90
        )
        beam.colors = [
            NSColor.clear.cgColor,
            Self.scanBlue.withAlphaComponent(0.5).cgColor,
            NSColor.clear.cgColor,
        ]
        beam.locations = [0, 0.5, 1]
        beam.startPoint = CGPoint(x: 0.5, y: 0)
        beam.endPoint = CGPoint(x: 0.5, y: 1)
        beam.opacity = 0

        beamClip.addSublayer(beam)
        layer?.addSublayer(beamClip)
    }

    private func configureSuccessLayer() {
        let side: CGFloat = 64
        successLayer.frame = CGRect(
            x: ScannerPanel.viewfinderRect.midX - side / 2,
            y: ScannerPanel.viewfinderRect.midY - side / 2,
            width: side,
            height: side
        )
        successLayer.opacity = 0
        successLayer.contents = Self.successImage()?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        successLayer.contentsScale = 2
        layer?.addSublayer(successLayer)
    }

    private func startBeam() {
        beam.removeAllAnimations()

        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0
        move.toValue = 410
        move.duration = 1.5

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.85, 1]
        fade.duration = 1.5

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 1.5
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)

        beam.opacity = 1
        beam.add(group, forKey: "sweep")
    }

    private func stopBeam() {
        beam.removeAnimation(forKey: "sweep")
        beam.opacity = 0
    }

    func showSuccess(then completion: @escaping () -> Void) {
        phase = .success
        successLayer.removeAllAnimations()
        successLayer.opacity = 1

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.7
        scale.toValue = 1
        scale.duration = 0.18
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18

        successLayer.add(scale, forKey: "scale")
        successLayer.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: completion)
    }

    private static let scanBlue = NSColor(
        calibratedRed: 0.43,
        green: 0.78,
        blue: 1,
        alpha: 1
    )

    private static func successImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6))
            NSColor(calibratedRed: 0.33, green: 0.7, blue: 1, alpha: 0.96).setFill()
            circle.fill()

            let check = NSBezierPath()
            check.lineWidth = 11
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            // NSImage 是 y 向上坐标：拐点必须比两端低，才是 ✓。
            check.move(to: NSPoint(x: 37, y: 62))
            check.line(to: NSPoint(x: 56, y: 43))
            check.line(to: NSPoint(x: 92, y: 82))
            NSColor.white.setStroke()
            check.stroke()
            return true
        }
        return image
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -6, dy: -6).contains(point) {
            onCancel?()
            return
        }

        onDragStart?()
        window?.performDrag(with: event)
        onDragEnd?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
