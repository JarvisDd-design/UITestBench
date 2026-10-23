import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UITestBenchCore

/// 冻结的画面 + 顶部工具条。标注画在 Canvas 上，保存时才真正烧进图片。
struct AnnotationEditorView: View {
    @Environment(\.benchPalette) private var palette
    @ObservedObject var model: AnnotationEditorModel
    var onClose: () -> Void

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                let mapper = CoordinateMapper(viewSize: proxy.size, deviceSize: model.imageSize)
                ZStack {
                    palette.canvas

                    Image(nsImage: model.displayImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(model.imageSize.width / model.imageSize.height, contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)

                    AnnotationCanvas(model: model, mapper: mapper)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(mapper))
                }
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .background(palette.canvas)
    }

    // MARK: - 工具条

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("工具", selection: $model.tool) {
                    ForEach(AnnotationEditorModel.Tool.allCases) { tool in
                        Image(systemName: tool.systemImage).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .help("选择标注工具")

                Divider().frame(height: 20)

                HStack(spacing: 7) {
                    ForEach(AnnotationColor.allCases, id: \.self) { color in
                        colorSwatch(color)
                    }
                }
                .help("标注颜色")

                Divider().frame(height: 20)

                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .help("撤销")

                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .help("重做")

                Button {
                    model.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.isEmpty)
                .help("清空标注")

                Spacer()

                Button {
                    model.copyToPasteboard()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Button {
                    save()
                } label: {
                    Label("保存…", systemImage: "square.and.arrow.down")
                }

                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }

            if model.tool == .text {
                HStack(spacing: 8) {
                    TextField("要标注的文字", text: $model.text)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Text("输入后点一下画面放置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let message = model.errorMessage {
                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(palette.error)
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private func colorSwatch(_ color: AnnotationColor) -> some View {
        Circle()
            .fill(color.swiftUIColor)
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        model.color == color ? Color.primary : Color.clear,
                        lineWidth: 2
                    )
                    .padding(-3)
            )
            .frame(width: 18, height: 18)
            .contentShape(Circle())
            .onTapGesture { model.color = color }
            .help(color.displayName)
    }

    // MARK: - 手势

    private func dragGesture(_ mapper: CoordinateMapper) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = imagePoint(value.location, mapper)
                if !isDragging {
                    isDragging = true
                    model.begin(at: point)
                }
                model.update(to: point)
            }
            .onEnded { value in
                defer { isDragging = false }
                model.end(at: imagePoint(value.location, mapper), scale: mapper.scale)
            }
    }

    /// 拖到画面外的部分夹回边缘，箭头和矩形不会突然跳走。
    private func imagePoint(_ location: CGPoint, _ mapper: CoordinateMapper) -> CGPoint {
        let rect = mapper.contentRect
        let clamped = CGPoint(
            x: min(max(location.x, rect.minX), rect.maxX),
            y: min(max(location.y, rect.minY), rect.maxY)
        )
        return mapper.devicePoint(from: clamped) ?? .zero
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "UI验收台-\(formatter.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.save(to: url)
    }
}

/// 屏幕预览：已提交的标注与正在拖的这一笔，都按视图缩放画出来。
private struct AnnotationCanvas: View {
    @ObservedObject var model: AnnotationEditorModel
    let mapper: CoordinateMapper

    var body: some View {
        Canvas { context, _ in
            for annotation in model.document.annotations {
                draw(annotation, in: context)
            }
            if let shape = model.draft {
                draw(
                    Annotation(
                        shape: shape,
                        color: model.color,
                        lineWidth: model.lineWidth,
                        fontSize: model.fontSize
                    ),
                    in: context
                )
            }
        }
    }

    private func draw(_ annotation: Annotation, in context: GraphicsContext) {
        let scale = mapper.scale
        guard scale > 0 else { return }
        let color = annotation.color.swiftUIColor
        let style = StrokeStyle(
            lineWidth: annotation.lineWidth * scale,
            lineCap: .round,
            lineJoin: .round
        )

        switch annotation.shape {
        case let .rectangle(rect):
            guard let topLeft = mapper.viewPoint(from: CGPoint(x: rect.minX, y: rect.minY)),
                  let bottomRight = mapper.viewPoint(from: CGPoint(x: rect.maxX, y: rect.maxY))
            else { return }
            let viewRect = CGRect(
                x: topLeft.x,
                y: topLeft.y,
                width: bottomRight.x - topLeft.x,
                height: bottomRight.y - topLeft.y
            )
            context.stroke(Path(viewRect), with: .color(color), style: style)

        case let .arrow(from, to):
            guard let start = mapper.viewPoint(from: from),
                  let end = mapper.viewPoint(from: to)
            else { return }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)

            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLength = max(10, annotation.lineWidth * 3.5) * scale
            let spread = CGFloat.pi / 7
            for side in [-spread, spread] {
                path.move(to: end)
                path.addLine(to: CGPoint(
                    x: end.x - headLength * cos(angle + side),
                    y: end.y - headLength * sin(angle + side)
                ))
            }
            context.stroke(path, with: .color(color), style: style)

        case let .freehand(points):
            let mapped = points.compactMap { mapper.viewPoint(from: $0) }
            guard let first = mapped.first else { return }
            if mapped.count == 1 {
                let radius = annotation.lineWidth * scale / 2
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: first.x - radius,
                        y: first.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(color)
                )
                return
            }
            var path = Path()
            path.move(to: first)
            for point in mapped.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(color), style: style)

        case let .text(origin, content):
            guard let point = mapper.viewPoint(from: origin) else { return }
            context.draw(
                Text(content)
                    .font(.system(size: annotation.fontSize * scale))
                    .foregroundColor(color),
                at: point,
                anchor: .topLeading
            )
        }
    }
}
