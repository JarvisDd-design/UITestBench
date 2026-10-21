import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把标注画进截图，得到可以保存或复制的新图片。
///
/// 标注坐标以图片左上角为原点；Core Graphics 默认原点在左下角，
/// 所以画之前整体翻转一次，文字再局部翻回来。
public enum AnnotationRenderer {
    public static func render(_ annotations: [Annotation], over image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        for annotation in annotations {
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(annotation.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            draw(annotation, in: context)
        }

        return context.makeImage()
    }

    public static func pngData(_ annotations: [Annotation], over image: CGImage) -> Data? {
        guard let rendered = render(annotations, over: image) else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func draw(_ annotation: Annotation, in context: CGContext) {
        switch annotation.shape {
        case let .rectangle(rect):
            context.stroke(rect)

        case let .arrow(from, to):
            context.move(to: from)
            context.addLine(to: to)

            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength = max(10, annotation.lineWidth * 3.5)
            let spread = CGFloat.pi / 7
            for side in [-spread, spread] {
                context.move(to: to)
                context.addLine(to: CGPoint(
                    x: to.x - headLength * cos(angle + side),
                    y: to.y - headLength * sin(angle + side)
                ))
            }
            context.strokePath()

        case let .freehand(points):
            guard let first = points.first else { return }
            guard points.count > 1 else {
                let radius = annotation.lineWidth / 2
                context.fillEllipse(
                    in: CGRect(x: first.x - radius, y: first.y - radius,
                               width: radius * 2, height: radius * 2)
                )
                return
            }
            context.move(to: first)
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()

        case let .text(origin, content):
            drawText(content, at: origin, annotation: annotation, in: context)
        }
    }

    private static func drawText(
        _ content: String,
        at origin: CGPoint,
        annotation: Annotation,
        in context: CGContext
    ) {
        guard !content.isEmpty else { return }

        // 系统自带的苹方能显示中文；没有时 CoreText 会自动回退。
        let font = CTFontCreateWithName("PingFang SC" as CFString, annotation.fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: content, attributes: attributes)
        )

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        // 抵消外层翻转，否则文字是倒的。
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: -CTFontGetAscent(font))
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
