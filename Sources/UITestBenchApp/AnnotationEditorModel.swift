import AppKit
import Foundation
import ImageIO
import SwiftUI
import UITestBenchCore

/// 截图编辑器：一张冻结的画面 + 一组标注 + 工具与颜色。
///
/// 坐标全程用图片像素（左上角原点），视图层负责换算成屏幕坐标；
/// 导出时交给 `AnnotationRenderer`，屏幕预览走 SwiftUI Canvas。
@MainActor
final class AnnotationEditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case rectangle
        case arrow
        case freehand
        case text

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rectangle: return "矩形"
            case .arrow: return "箭头"
            case .freehand: return "画笔"
            case .text: return "文字"
            }
        }

        var systemImage: String {
            switch self {
            case .rectangle: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .freehand: return "pencil"
            case .text: return "textformat"
            }
        }
    }

    let cgImage: CGImage
    let displayImage: NSImage

    @Published private(set) var document = AnnotationDocument()
    @Published private(set) var draft: AnnotationShape?
    @Published var tool: Tool = .rectangle
    @Published var color: AnnotationColor = .red
    @Published var text = ""
    @Published private(set) var errorMessage: String?

    private var dragStart: CGPoint?
    private var draftPoints: [CGPoint] = []

    init(pngData: Data) throws {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ScreenshotError.invalidPNG
        }
        cgImage = image
        // 以像素尺寸建 NSImage，视图再等比缩放；这样显示与导出是同一张图。
        displayImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    var imageSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    /// 线宽与字号跟着截图尺寸走，换机型后标注的粗细看起来一致。
    var lineWidth: CGFloat {
        max(4, min(imageSize.width, imageSize.height) * 0.004)
    }

    var fontSize: CGFloat {
        max(24, min(imageSize.width, imageSize.height) * 0.03)
    }

    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }
    var isEmpty: Bool { document.isEmpty }

    // MARK: - 绘制

    func begin(at point: CGPoint) {
        dragStart = point
        draftPoints = [point]
        switch tool {
        case .rectangle:
            draft = .rectangle(CGRect(origin: point, size: .zero))
        case .arrow:
            draft = .arrow(from: point, to: point)
        case .freehand:
            draft = .freehand([point])
        case .text:
            draft = nil
        }
    }

    func update(to point: CGPoint) {
        guard let start = dragStart else { return }
        switch tool {
        case .rectangle:
            draft = .rectangle(Self.rect(from: start, to: point))
        case .arrow:
            draft = .arrow(from: start, to: point)
        case .freehand:
            if let last = draftPoints.last, hypot(point.x - last.x, point.y - last.y) < 2 {
                return
            }
            draftPoints.append(point)
            draft = .freehand(draftPoints)
        case .text:
            break
        }
    }

    /// `scale` 是图片像素到屏幕点的比例，用来判断「这一下算点击还是拖动」。
    func end(at point: CGPoint, scale: CGFloat) {
        defer {
            dragStart = nil
            draftPoints = []
            draft = nil
        }
        guard let start = dragStart else { return }
        let dragged = hypot(point.x - start.x, point.y - start.y) * scale

        switch tool {
        case .rectangle:
            let rect = Self.rect(from: start, to: point)
            guard rect.width * scale >= 4, rect.height * scale >= 4 else { return }
            add(.rectangle(rect))

        case .arrow:
            guard dragged >= 8 else { return }
            add(.arrow(from: start, to: point))

        case .freehand:
            guard draftPoints.count > 1 else { return }
            add(.freehand(draftPoints))

        case .text:
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                errorMessage = "先在工具栏输入要标注的文字，再点一下画面。"
                return
            }
            guard dragged <= 8 else { return }
            errorMessage = nil
            add(.text(origin: start, content: content))
        }
    }

    func cancelDraft() {
        dragStart = nil
        draftPoints = []
        draft = nil
    }

    private func add(_ shape: AnnotationShape) {
        document.add(
            Annotation(
                shape: shape,
                color: color,
                lineWidth: lineWidth,
                fontSize: fontSize
            )
        )
    }

    private static func rect(from start: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
    }

    // MARK: - 撤销与导出

    func undo() { document.undo() }
    func redo() { document.redo() }
    func clear() { document.removeAll() }

    func pngData() -> Data? {
        AnnotationRenderer.pngData(document.annotations, over: cgImage)
    }

    func copyToPasteboard() {
        guard let data = pngData() else {
            errorMessage = "导出图片失败，请重试。"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        errorMessage = nil
    }

    func save(to url: URL) {
        guard let data = pngData() else {
            errorMessage = "导出图片失败，请重试。"
            return
        }
        do {
            try data.write(to: url)
            errorMessage = nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

extension AnnotationColor {
    var swiftUIColor: Color {
        let value = components
        return Color(red: value.red, green: value.green, blue: value.blue)
    }
}
