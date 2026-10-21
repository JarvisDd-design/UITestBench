import Foundation

/// scrcpy 服务端的推送、端口转发与启动参数。
///
/// 参数名与顺序对锁 v5.0.1 客户端 `app/src/server.c`。
public enum ScrcpyServerCommand {
    public static let jarPathOnDevice = "/data/local/tmp/scrcpy-server.jar"

    public static func socketName(scid: UInt32) -> String {
        String(format: "scrcpy_%08x", scid)
    }

    public static func pushArguments(localJar: URL) -> [String] {
        ["push", localJar.path, jarPathOnDevice]
    }

    public static func forwardArguments(port: Int, scid: UInt32) -> [String] {
        ["forward", "tcp:\(port)", "localabstract:\(socketName(scid: scid))"]
    }

    public static func removeForwardArguments(port: Int) -> [String] {
        ["forward", "--remove", "tcp:\(port)"]
    }

    /// 不含 `adb` 与 `-s <serial>`，由调用方拼接。
    public static func shellArguments(
        scid: UInt32,
        maxSize: Int? = nil,
        maxFPS: Int? = nil
    ) -> [String] {
        var arguments = [
            "shell",
            "CLASSPATH=\(jarPathOnDevice)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            ScrcpyProtocol.version,
            String(format: "scid=%08x", scid),
            "log_level=info",
            "tunnel_forward=true",
            "audio=false",
            // 服务端会先等控制 socket 连上再发设备名与尺寸；
            // 客户端在读握手之前就把两条连接都建好。
            "control=true",
            // 默认的服务端退出清理是异步的：上一条会话的清理可能晚一步，
            // 把下一次刚推上去的共享 jar 删掉。jar 的生命周期由客户端管理。
            "cleanup=false"
        ]
        if let maxSize {
            arguments.append("max_size=\(maxSize)")
        }
        if let maxFPS {
            arguments.append("max_fps=\(maxFPS)")
        }
        return arguments
    }
}
