import CoreImage
import XCTest

/// 现场生成二维码图片，避免依赖外部素材文件。
enum QRCodeFixture {
    static func pngData(encoding payload: String) throws -> Data {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage)
        // 原图只有几十像素，放大后检测器才稳定。
        return try pngData(of: output.transformed(by: CGAffineTransform(scaleX: 10, y: 10)))
    }

    /// 一张没有二维码的白图。
    static func plainPNGData() throws -> Data {
        let image = CIImage(color: CIColor.white)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        return try pngData(of: image)
    }

    private static func pngData(of image: CIImage) throws -> Data {
        let context = CIContext()
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: image.extent))
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
