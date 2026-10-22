import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// 现场生成二维码图片，避免依赖外部素材文件。
enum QRCodeFixture {
    static func pngData(encoding payload: String, scale: CGFloat = 10) throws -> Data {
        try pngData(of: try qrImage(encoding: payload, scale: scale))
    }

    static func cgImage(encoding payload: String, scale: CGFloat = 10) throws -> CGImage {
        try cgImage(of: try qrImage(encoding: payload, scale: scale))
    }

    /// 反色二维码：白模块、黑底，模拟暗色主题里的截图。
    static func invertedPNGData(encoding payload: String, scale: CGFloat = 10) throws -> Data {
        let inverted = try qrImage(encoding: payload, scale: scale)
            .applyingFilter("CIColorInvert")
        return try pngData(of: inverted)
    }

    /// 带 EXIF 方向的 JPEG，模拟手机截图/转发图片。
    static func jpegData(
        encoding payload: String,
        scale: CGFloat = 8,
        quality: CGFloat = 0.5,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> Data {
        try jpegData(
            of: cgImage(encoding: payload, scale: scale),
            quality: quality,
            orientation: orientation
        )
    }

    static func jpegData(
        of image: CGImage,
        quality: CGFloat = 0.8,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation.rawValue,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 一块纯色图，用来测方向旋转后的宽高变化。
    static func solidCGImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 一张没有二维码的白图。
    static func plainPNGData() throws -> Data {
        let image = CIImage(color: CIColor.white)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        return try pngData(of: image)
    }

    /// 把多个二维码画在同一张画布上，用来测「取离中心最近的那个」。
    static func compositeCGImage(
        codes: [(payload: String, rect: CGRect)],
        canvas: CGSize
    ) throws -> CGImage {
        var image = CIImage(color: CIColor.white)
            .cropped(to: CGRect(origin: .zero, size: canvas))
        for code in codes {
            let qr = try qrImage(encoding: code.payload, scale: 1)
            let scale = min(code.rect.width / qr.extent.width, code.rect.height / qr.extent.height)
            let scaled = qr.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = scaled.transformed(
                by: CGAffineTransform(translationX: code.rect.minX, y: code.rect.minY)
            )
            image = placed.composited(over: image)
        }
        return try cgImage(of: image)
    }

    static func pixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        let width = cgImage.width
        let height = cgImage.height
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CIContext().render(
            CIImage(cgImage: cgImage),
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixelBuffer
    }

    // MARK: - 工具

    private static func qrImage(encoding payload: String, scale: CGFloat) throws -> CIImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage)
        return output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func pngData(of image: CIImage) throws -> Data {
        try pngData(of: cgImage(of: image))
    }

    static func pngData(of cgImage: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private static func cgImage(of image: CIImage) throws -> CGImage {
        let context = CIContext()
        return try XCTUnwrap(context.createCGImage(image, from: image.extent))
    }
}
