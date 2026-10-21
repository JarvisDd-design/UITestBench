import Foundation
import SwiftUI
import UITestBenchCore

/// 截图入口：抓一张画面，然后交给标注编辑器。
@MainActor
final class ScreenshotModel: ObservableObject {
    @Published private(set) var editor: AnnotationEditorModel?
    @Published private(set) var isCapturing = false
    @Published private(set) var errorMessage: String?

    private var capturer: ScreenshotCapturer?
    private var currentTask: Task<Void, Never>?

    func attach(serial: String, sdkDirectory: URL) {
        capturer = ScreenshotCapturer(sdkDirectory: sdkDirectory, serial: serial)
        errorMessage = nil
    }

    func detach() {
        currentTask?.cancel()
        currentTask = nil
        capturer = nil
        isCapturing = false
        editor = nil
    }

    func capture() {
        guard let capturer, !isCapturing else { return }
        isCapturing = true
        errorMessage = nil

        currentTask = Task {
            defer { isCapturing = false }
            do {
                let pngData = try await capturer.capture()
                guard !Task.isCancelled else { return }
                editor = try AnnotationEditorModel(pngData: pngData)
            } catch let error as ScreenshotError {
                guard !Task.isCancelled else { return }
                errorMessage = error.explanation
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "截图失败：\(error.localizedDescription)"
            }
        }
    }

    func closeEditor() {
        editor = nil
    }
}
