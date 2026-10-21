import Foundation
import UITestBenchCore

/// 随包资源在两种工程形态下的位置不同：SwiftPM 把它们放进单独的资源包，
/// Xcode 工程则直接拷进 app 的 Resources。这里把两处都列出来，交给核心库挑选。
enum AppResources {
    static var searchDirectories: [URL] {
        var directories: [URL] = []
        #if SWIFT_PACKAGE
        if let bundleURL = Bundle.module.resourceURL {
            directories.append(bundleURL)
        }
        #endif
        if let mainURL = Bundle.main.resourceURL {
            directories.append(mainURL)
        }
        return directories
    }

    static var scrcpyServerJarURL: URL? {
        ScrcpyServerJar.locate(in: searchDirectories)
    }

    static var scrcpyLicenseURL: URL? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent("scrcpy-LICENSE.txt")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
