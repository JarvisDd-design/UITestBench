import Foundation

/// 退出时的一次性清理：卸载被测应用、清数据、删掉 `tmp/`。
///
/// 顺序是有意的——先卸包（设备还在才卸得掉），再删临时文件。
/// 只要有一个包没卸掉，就保留会话记录，下次启动补卸；
/// 记录是「设备上可能还有东西」的凭据，不能先删。
public struct SessionShutdown {
    private let cleaner: SessionCleaner
    private let lifecycle: AppLifecycleRunning?
    private let packageNames: [String]

    public init(
        cleaner: SessionCleaner,
        lifecycle: AppLifecycleRunning?,
        packageNames: [String] = []
    ) {
        self.cleaner = cleaner
        self.lifecycle = lifecycle
        self.packageNames = packageNames
    }

    /// - Parameter clearsTemporaryData: 退出时清空 `tmp/`；只是停止设备时传 `false`，
    ///   会话还没结束，用户手上的 APK 还得能用。
    public func run(clearsTemporaryData: Bool = true) async {
        var names = Set(packageNames.filter { !$0.isEmpty })
        if let pending = try? cleaner.pendingPackageNames() {
            names.formUnion(pending)
        }
        let targets = names.sorted()

        // 没卸掉的留着重试，卸掉的别让下次启动再卸一遍。
        var failed = Set<String>()
        if let lifecycle {
            for name in targets {
                try? await lifecycle.clearData(packageName: name)
                do {
                    try await lifecycle.uninstall(packageName: name)
                } catch {
                    failed.insert(name)
                }
            }
        } else if !targets.isEmpty {
            // 设备没起来，adb 无从下手；记录留着，下次启动补卸。
            failed.formUnion(targets)
        }

        if clearsTemporaryData {
            try? cleaner.clearTemporaryData()
        }
        try? cleaner.replacePending(failed.sorted())
    }
}
