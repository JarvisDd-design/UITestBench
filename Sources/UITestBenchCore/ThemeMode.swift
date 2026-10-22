import Foundation

/// 只做浅色/深色两态，不跟随系统。
public enum ThemeMode: String, CaseIterable, Equatable, Sendable {
    case light
    case dark

    public static let defaultMode: ThemeMode = .light
    public static let userDefaultsKey = "UITestBench.themeMode"
}

/// 读写持久化的主题；缺省或无法识别时回退到浅色。
public struct ThemePreference {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var mode: ThemeMode {
        get {
            guard let raw = defaults.string(forKey: ThemeMode.userDefaultsKey),
                  let mode = ThemeMode(rawValue: raw)
            else {
                return .defaultMode
            }
            return mode
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: ThemeMode.userDefaultsKey)
        }
    }
}
