import Foundation

/// 真实环境验收测试的公共约定。
///
///     UITESTBENCH_REAL_SETUP=1  swift test --filter RealEnvironmentAcceptanceTests
///
/// 默认每次都在临时目录里从零安装、跑完删除（约 2 GB 下载）。
/// 设 `UITESTBENCH_SDK_DIR` 可复用一份已装好的 SDK，开发时反复跑不必重下。
/// 该变量在所有真实环境测试里都表示**支持目录**（其下才是 `sdk/`、`avd/`），
/// 与 `AppPaths` 的语义一致，不要传 `sdk/` 本身。
enum RealEnvironment {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["UITESTBENCH_REAL_SETUP"] == "1"
    }

    /// 返回支持目录，以及跑完是否应当删除它。
    static func supportDirectory(purpose: String) throws -> (url: URL, isTemporary: Bool) {
        if let path = ProcessInfo.processInfo.environment["UITESTBENCH_SDK_DIR"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, false)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(purpose)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, true)
    }

    /// 随包资源里的 scrcpy jar：测试从源码树里的那一份取。
    static func scrcpyJarURL() -> URL {
        URL(fileURLWithPath: #filePath)          // Tests/UITestBenchCoreTests/…
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/UITestBenchApp/Resources/scrcpy-server.jar")
    }
}
