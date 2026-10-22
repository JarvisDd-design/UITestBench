import Combine
import Foundation
import UITestBenchCore

/// 主题的状态源：界面只读 `mode`，切换时同步写回 UserDefaults。
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var mode: ThemeMode

    private let preference: ThemePreference

    init(preference: ThemePreference = ThemePreference()) {
        self.preference = preference
        self.mode = preference.mode
    }

    func set(_ mode: ThemeMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        preference.mode = mode
    }

    func toggle() {
        set(mode == .light ? .dark : .light)
    }
}
