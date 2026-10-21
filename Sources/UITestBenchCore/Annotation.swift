import CoreGraphics
import Foundation

public enum AnnotationColor: String, CaseIterable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case black
    case white

    public var displayName: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .black: return "黑"
        case .white: return "白"
        }
    }

    public var components: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        switch self {
        case .red: return (0.91, 0.20, 0.20, 1)
        case .orange: return (1.00, 0.58, 0.00, 1)
        case .yellow: return (1.00, 0.80, 0.00, 1)
        case .green: return (0.16, 0.65, 0.31, 1)
        case .blue: return (0.12, 0.45, 0.90, 1)
        case .black: return (0, 0, 0, 1)
        case .white: return (1, 1, 1, 1)
        }
    }

    public var cgColor: CGColor {
        let color = components
        return CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// 坐标都是图片像素，原点在左上角——与界面里看到的方向一致。
public enum AnnotationShape: Equatable, Sendable {
    case rectangle(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case text(origin: CGPoint, content: String)
    case freehand([CGPoint])
}

public struct Annotation: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var shape: AnnotationShape
    public var color: AnnotationColor
    public var lineWidth: CGFloat
    public var fontSize: CGFloat

    public init(
        id: UUID = UUID(),
        shape: AnnotationShape,
        color: AnnotationColor = .red,
        lineWidth: CGFloat = 4,
        fontSize: CGFloat = 24
    ) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }
}

/// 一张截图上的标注与它的撤销史。
public struct AnnotationDocument: Equatable {
    public private(set) var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []

    public init() {}

    public var canUndo: Bool { !annotations.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var isEmpty: Bool { annotations.isEmpty }

    public mutating func add(_ annotation: Annotation) {
        annotations.append(annotation)
        // 画了新东西之后，之前撤销掉的步骤就接不上了。
        redoStack.removeAll()
    }

    public mutating func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
    }

    public mutating func redo() {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
    }

    public mutating func removeAll() {
        annotations.removeAll()
        redoStack.removeAll()
    }
}
