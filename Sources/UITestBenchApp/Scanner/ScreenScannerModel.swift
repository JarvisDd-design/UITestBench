import AppKit
import Foundation
import ScreenCaptureKit
import UITestBenchCore

/// 扫描编排：权限 → 取景框 → 实时捕获 → 识别 → 命中/取消 → 恢复主窗口。
///
/// 决策（哪个码、什么时候算命中）都在 Core 的 `ScanSession` 里，这里只负责
/// 把帧送进去、把结果画出来。捕获与 Vision 都不在主线程跑。
///
/// 每一轮扫描有自己的 `scanID`。取消、超时或开始下一轮后，上一轮在途的
/// 启动、识别结果、闪白完成都不能再改动界面。
@MainActor
final class ScreenScannerModel: ObservableObject {
    enum Issue: Equatable {
        /// 还没授权，或授权在本次启动后未生效（需要重启应用）。
        case notGranted
        /// 授权看似有了，但一帧都没拿到。
        case grantedButNoFrames
        case interrupted(String)
        /// 刚清掉失效的 TCC 记录，必须重启应用才能重新授权。
        case resetNeedsRestart

        var title: String {
            switch self {
            case .notGranted: return "还没有屏幕录制权限"
            case .grantedButNoFrames: return "没有拿到屏幕画面"
            case .interrupted: return "屏幕捕获中断了"
            case .resetNeedsRestart: return "授权已重置，需要重启应用"
            }
        }

        var message: String {
            switch self {
            case .notGranted:
                return "macOS 需要这项权限来读取取景框里的画面。请在系统设置的「隐私与安全性 → 屏幕录制」中勾选「UI验收台」，然后重启应用（macOS 12 上这一项在「系统偏好设置 → 安全性与隐私 → 隐私」里）。\n\n如果系统设置里已经显示开启、应用却仍提示未授权，说明旧版本的授权记录已经失效。点「重置授权」清掉它，再退出并重新打开应用，然后重新点扫描授权。"
            case .grantedButNoFrames:
                return "权限已勾选，但画面还没生效。请退出并重新打开 UI验收台；仍不行就在系统设置里取消勾选再重新勾选，或点「重置授权」后重启。"
            case .interrupted:
                // 底层错误说明是英文系统文案，不直接甩给设计同事。
                return "屏幕捕获被系统中断了。先点「重试扫描」；如果反复出现，改用截图或重启应用。"
            case .resetNeedsRestart:
                return "屏幕录制授权记录已清除。请退出 UI验收台再重新打开，然后点「扫描屏幕二维码」，系统会重新询问授权。"
            }
        }

        /// 中断与「已重置」都不是权限按钮能解决的，别误导用户。
        var offersPermissionActions: Bool {
            switch self {
            case .notGranted, .grantedButNoFrames: return true
            case .interrupted, .resetNeedsRestart: return false
            }
        }
    }

    enum State: Equatable {
        case idle
        case scanning
        case permissionDenied(Issue)
        case failed(String)
    }

    /// 取景框位置与捕获层对完之后的结果。
    private enum RegionResult {
        case applied
        case deferred
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var hint = ""

    /// 命中一个可下载链接。由 APK 面板接手，弹确认条，不自动下载。
    var onHit: ((DownloadLink) -> Void)?
    /// 用户选择「改用截图…」。
    var onFallback: (() -> Void)?

    private var capture: (any ScreenCapturing)?
    private var panel: ScannerPanel?
    private var isDarkAppearance = false
    private var analyzer: FrameAnalyzer?
    private weak var mainWindow: NSWindow?
    private var timeoutTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    /// 准备期计时：到点才开始判定并启动光带。
    private var armingTask: Task<Void, Never>?
    /// 当前轮次。推进它会让上一轮的迟到回调全部失效。
    private var scanID = 0
    private var isFinishing = false
    /// 拖动轮次：迟到的区域更新不能替新一轮拖动解暂停。
    private var dragRevision = 0
    private var isDragging = false

    var isScanning: Bool {
        state == .scanning
    }

    func setDarkAppearance(_ dark: Bool) {
        isDarkAppearance = dark
        panel?.applyTheme(dark: dark)
    }

    // MARK: - 生命周期

    func start(from window: NSWindow?) {
        guard !isScanning else { return }
        guard #available(macOS 12.3, *) else {
            state = .failed("屏幕扫码需要 macOS 12.3 或更高版本。")
            return
        }

        mainWindow = resolveMainWindow(window)

        if !ScreenCapturePermission.isGranted {
            guard explainPermission() else { return }
            guard ScreenCapturePermission.request() else {
                state = .permissionDenied(.notGranted)
                return
            }
        }

        begin()
    }

    func cancel() {
        guard isScanning else { return }
        finishScan()
        restoreMainWindow()
    }

    /// 应用退出或主窗口关闭：不碰窗口，只保证流停掉、录制指示灯熄灭。
    func shutdown() {
        scanID += 1
        dragRevision += 1
        isDragging = false
        timeoutTask?.cancel()
        timeoutTask = nil
        hintTask?.cancel()
        hintTask = nil
        armingTask?.cancel()
        armingTask = nil

        let capture = self.capture
        self.capture = nil
        capture?.pause()
        if let capture {
            Task { await capture.stop() }
        }
        analyzer = nil
        panel?.orderOut(nil)
        panel?.phase = .preparing
        panel?.hint = "正在准备…"
        hint = ""
        isFinishing = false
        state = .idle
    }

    // MARK: - 权限卡片动作

    func openSystemSettings() {
        ScreenCapturePermission.openSystemSettings()
    }

    func recheckPermission() {
        guard ScreenCapturePermission.isGranted else {
            // 用户刚去设置里看过但仍然没勾上：把说明留在界面上。
            state = .permissionDenied(.notGranted)
            return
        }
        state = .idle
        start(from: NSApp.keyWindow)
    }

    /// 清掉失效的屏幕录制记录。系统设置里开关看着是开的、应用却一直提示
    /// 未授权时，这是唯一能让系统重新弹授权窗的办法。
    func resetPermission() {
        Task { [weak self] in
            let succeeded = await Task.detached(priority: .userInitiated) {
                ScreenCapturePermission.reset()
            }.value

            guard let self else { return }
            if succeeded {
                self.state = .permissionDenied(.resetNeedsRestart)
            } else {
                self.state = .failed(
                    "没能清除屏幕录制授权。请到系统设置里选中「UI验收台」或「UITestBenchApp」，点「−」移除，再重新打开本应用。"
                )
            }
        }
    }

    func dismissIssue() {
        state = .idle
    }

    func useScreenshotFallback() {
        state = .idle
        onFallback?()
    }

    // MARK: - 开始扫描

    private func explainPermission() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = """
        UI验收台要读取取景框里的画面来识别二维码。画面只在本机内存中分析，不会保存或上传。

        授权后如果仍看不到画面，请退出并重新打开 UI验收台。
        """
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func begin() {
        guard #available(macOS 12.3, *) else { return }

        let panel = self.panel ?? ScannerPanel()
        self.panel = panel
        panel.applyTheme(dark: isDarkAppearance)
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onDragStart = { [weak self] in self?.dragDidStart() }
        panel.onDragEnd = { [weak self] in self?.dragDidEnd() }
        panel.phase = .preparing
        panel.hint = "正在准备…"
        panel.setFrame(ScannerPanel.centeredOnMouseScreen(), display: true)

        guard let panelScreen = panel.screen ?? NSScreen.main else {
            state = .failed("取景框不在任何屏幕里，请重新打开扫描。")
            return
        }
        let screen = CaptureScreen(panelScreen)
        guard let region = region(for: panel, on: panelScreen) else {
            state = .failed("取景框不在任何屏幕里，请重新打开扫描。")
            return
        }

        scanID += 1
        dragRevision += 1
        isDragging = false
        let id = scanID

        // 取景框出现后的 2 秒只预热：捕获照常启动，把 SCStream 的启动时间
        // 藏进准备期，但不判定任何结果。时间基准与帧时间戳同为 systemUptime。
        let armedAt = ProcessInfo.processInfo.systemUptime + 2
        let analyzer = FrameAnalyzer(
            detector: VisionBarcodeDetector(),
            startAt: armedAt
        ) { [weak self] outcome in
            Task { @MainActor in self?.handle(outcome, id: id) }
        }
        self.analyzer = analyzer

        isFinishing = false
        hint = "正在准备…"
        state = .scanning

        panel.orderFrontRegardless()
        panel.makeKey()
        mainWindow?.miniaturize(nil)

        armingTask?.cancel()
        armingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  id == self.scanID,
                  self.isScanning,
                  !self.isFinishing
            else { return }

            self.panel?.phase = .scanning
            self.hint = "把二维码放进框里"
            self.panel?.hint = "把二维码放进框里"
        }

        let capture = ScreenRegionCapture()
        self.capture = capture

        Task { [weak self] in
            guard let self else { return }
            _ = await self.startCapture(capture, region: region, screen: screen, id: id)
        }
    }

    // MARK: - 捕获启动与区域对齐

    /// 启动捕获并把当前取景框位置对齐到流上。返回是否成功。
    @discardableResult
    private func startCapture(
        _ capture: any ScreenCapturing,
        region: CaptureRegion,
        screen: CaptureScreen,
        id: Int,
        applyRegionAfterStart: Bool = true
    ) async -> Bool {
        guard id == scanID, isScanning, let analyzer else { return false }

        do {
            try await capture.start(
                region: region,
                screen: screen,
                onFrame: { buffer, timestamp in
                    analyzer.submit(buffer, at: timestamp)
                },
                onFailure: { [weak self] error in
                    Task { @MainActor in self?.handleCaptureFailure(error, id: id) }
                }
            )
        } catch is CancellationError {
            // 本轮已被取消或被新一轮顶替，收尾由取消方负责。
            return false
        } catch {
            handleCaptureFailure(error, id: id)
            return false
        }

        // 启动期间用户可能已经按 Esc；这条流必须自己停掉。
        guard id == scanID, isScanning else {
            await capture.stop()
            return false
        }

        // 启动期间用户可能正在拖动：保持暂停，等松手后再恢复。
        if isDragging {
            capture.pause()
        }
        armNoFrameTimeout(id: id)

        if applyRegionAfterStart {
            let result = await applyCurrentRegion(capture, id: id)
            guard id == scanID, isScanning else { return false }
            if !isDragging, !isFinishing {
                capture.resume()
            }
            armNoFrameTimeout(id: id)
            if case .failed = result { return false }
        }
        return true
    }

    /// 把捕获对到取景框当前位置。跨屏时会重建流；重建后必须再绕一圈，
    /// 因为拖动可能就发生在重建的这几百毫秒里。
    @discardableResult
    private func applyCurrentRegion(_ capture: any ScreenCapturing, id: Int) async -> RegionResult {
        for _ in 0..<3 {
            guard id == scanID, isScanning else { return .deferred }
            guard let panel,
                  let panelScreen = panel.screen ?? NSScreen.main,
                  let region = region(for: panel, on: panelScreen)
            else { return .deferred }

            let screen = CaptureScreen(panelScreen)
            switch await capture.updateRegion(region, screen: screen) {
            case .applied:
                return .applied
            case .deferred:
                return .deferred
            case .needsRestart:
                await capture.stop()
                guard id == scanID, isScanning else { return .deferred }
                // 重启后回到循环顶部重新读一次取景框位置，不能直接返回。
                let restarted = await startCapture(
                    capture,
                    region: region,
                    screen: screen,
                    id: id,
                    applyRegionAfterStart: false
                )
                guard restarted else { return .failed }
            }
        }

        // 极端情况下连续换屏：最后再对一次当前位置。
        guard id == scanID, isScanning,
              let panel,
              let panelScreen = panel.screen ?? NSScreen.main,
              let region = region(for: panel, on: panelScreen)
        else { return .deferred }
        let final = await capture.updateRegion(region, screen: CaptureScreen(panelScreen))
        guard id == scanID, isScanning else { return .deferred }
        return final == .applied ? .applied : .failed
    }

    private func region(for panel: ScannerPanel, on screen: NSScreen) -> CaptureRegion? {
        // 卡片比取景区大，捕获只能取中间镂空那块；否则玻璃边框和标题会被拍进去。
        CaptureRegionCalculator.region(
            panelFrame: panel.captureFrameInScreen,
            screenFrame: screen.frame,
            backingScale: screen.backingScaleFactor
        )
    }

    // MARK: - 识别结果

    private func handle(_ outcome: ScanOutcome, id: Int) {
        guard id == scanID, isScanning, !isFinishing else { return }

        switch outcome {
        case .none:
            return

        case .notALink:
            showHint("识别到内容，但不是下载链接")

        case let .hit(link):
            // 先同步停帧，避免成功图标停留的 1 秒里又扫到别的码。
            isFinishing = true
            armingTask?.cancel()
            capture?.pause()
            panel?.hint = "已识别下载地址"
            panel?.showSuccess { [weak self] in
                Task { @MainActor in self?.completeHit(link, id: id) }
            }
        }
    }

    private func completeHit(_ link: DownloadLink, id: Int) {
        // 闪白的 180 ms 里用户仍可能按 Esc；取消了就别再把包塞回去。
        guard id == scanID, isFinishing, isScanning else { return }
        finishScan()
        restoreMainWindow()
        onHit?(link)
    }

    private func showHint(_ text: String) {
        hint = text
        panel?.hint = text

        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.isScanning else { return }
            self.hint = "把二维码放进框里"
            self.panel?.hint = "把二维码放进框里"
        }
    }

    // MARK: - 拖动与区域更新

    private func dragDidStart() {
        guard isScanning, !isFinishing else { return }
        isDragging = true
        dragRevision += 1
        // 拖动期间没有画面是正常的，别让无画面计时误伤；拖完再重新计时。
        timeoutTask?.cancel()
        timeoutTask = nil
        capture?.pause()
    }

    private func dragDidEnd() {
        guard isScanning, !isFinishing else { return }
        isDragging = false
        dragRevision += 1
        regionDidChange()
    }

    private func regionDidChange() {
        guard isScanning, let capture else { return }
        let id = scanID
        let revision = dragRevision

        Task { [weak self] in
            guard let self else { return }
            let result = await self.applyCurrentRegion(capture, id: id)
            guard id == self.scanID, self.isScanning else { return }

            // 这次更新已经被更新的一轮拖动顶替：交给它收尾，别解暂停、
            // 别重新武装计时，避免在拖动中途恢复出帧。
            guard revision == self.dragRevision, !self.isDragging, !self.isFinishing else { return }

            capture.resume()
            if case .failed = result {
                self.showHint("取景框更新失败，请重新打开扫描")
            }
            self.armNoFrameTimeout(id: id)
        }
    }

    // MARK: - 失败与收尾

    /// 启动成功后才计时；拖动期间取消，松手后重新计。
    private func armNoFrameTimeout(id: Int) {
        timeoutTask?.cancel()
        timeoutTask = nil

        // 用捕获层自己的标志：它在每次 start（包括跨屏重建）时重置，
        // 才能发现“新屏上一帧都没来”。
        guard id == scanID, isScanning, !isDragging,
              capture?.isRunning == true,
              capture?.hasReceivedFrame != true
        else { return }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, id == self.scanID, self.isScanning else { return }
            guard !self.isDragging,
                  self.capture?.isRunning == true,
                  self.capture?.hasReceivedFrame != true
            else { return }

            self.finishScan()
            self.restoreMainWindow()
            self.state = .permissionDenied(.grantedButNoFrames)
        }
    }

    private func handleCaptureFailure(_ error: Error, id: Int) {
        guard id == scanID, isScanning else { return }
        finishScan()
        restoreMainWindow()

        if Self.isPermissionDenied(error) {
            // 刚在系统弹窗里点了允许时，preflight 已经是 true，但本次进程
            // 仍可能拿不到画面——这时该提示重启，而不是让用户再授权一遍。
            state = .permissionDenied(
                ScreenCapturePermission.isGranted ? .grantedButNoFrames : .notGranted
            )
        } else {
            state = .permissionDenied(.interrupted(error.localizedDescription))
        }
    }

    private func finishScan() {
        // 先让本轮作废，再停捕获；在途的启动与迟到结果都不会再碰界面。
        scanID += 1
        dragRevision += 1
        isDragging = false
        timeoutTask?.cancel()
        timeoutTask = nil
        hintTask?.cancel()
        hintTask = nil
        armingTask?.cancel()
        armingTask = nil

        let capture = self.capture
        self.capture = nil
        capture?.pause()
        if let capture {
            Task { await capture.stop() }
        }

        analyzer = nil
        panel?.orderOut(nil)
        panel?.phase = .preparing
        panel?.hint = "正在准备…"
        hint = ""
        isFinishing = false
        state = .idle
    }

    private func restoreMainWindow() {
        guard let window = mainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func resolveMainWindow(_ given: NSWindow?) -> NSWindow? {
        if let given, !(given is ScannerPanel) { return given }
        if let key = NSApp.keyWindow, !(key is ScannerPanel) { return key }
        if let main = NSApp.mainWindow, !(main is ScannerPanel) { return main }
        return NSApp.windows.first {
            $0.isVisible && $0.canBecomeMain && !($0 is ScannerPanel)
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        if #available(macOS 12.3, *) {
            let nsError = error as NSError
            return nsError.domain == SCStreamError.errorDomain
                && nsError.code == SCStreamError.Code.userDeclined.rawValue
        }
        return false
    }
}

/// 在后台串行队列上跑 Vision；处理不过来就丢帧，结果回主线程。
/// 识别本身是同步的，不能放在主线程，否则拖取景框会卡。
final class FrameAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.uitestbench.scanner.analysis",
        qos: .userInitiated
    )
    private let session: ScanSession
    private let lock = NSLock()
    private var isBusy = false
    private var receivedFrame = false
    private let onOutcome: (ScanOutcome) -> Void

    init(
        detector: BarcodeDetecting,
        startAt: TimeInterval = 0,
        onOutcome: @escaping (ScanOutcome) -> Void
    ) {
        session = ScanSession(detector: detector, startAt: startAt)
        self.onOutcome = onOutcome
    }

    var hasReceivedFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedFrame
    }

    func submit(_ pixelBuffer: CVPixelBuffer, at timestamp: TimeInterval) {
        lock.lock()
        receivedFrame = true
        if isBusy {
            lock.unlock()
            return
        }
        isBusy = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.session.process(.pixelBuffer(pixelBuffer), at: timestamp)

            self.lock.lock()
            self.isBusy = false
            self.lock.unlock()

            guard outcome != .none else { return }
            DispatchQueue.main.async {
                self.onOutcome(outcome)
            }
        }
    }
}
