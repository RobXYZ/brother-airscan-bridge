import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns pages from the scanner into the JPEGs handed to eSCL clients.
public enum Imaging {
    /// Returns a JPEG of exactly `plan.width` x `plan.height` pixels. The scan is anchored
    /// top-left; anything the scanner didn't cover (its sensor is a little narrower than US
    /// Letter, and short sheets end early) is white.
    public static func jpeg(from page: RawPage, plan: ScanPlan) -> Data? {
        guard let image = decode(page) else { return nil }
        if page.format == .jpeg, image.width == plan.width, image.height == plan.height {
            return page.data   // already what was asked for: don't recompress
        }

        let gray = plan.colorMode != .color
        guard let context = CGContext(
            data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
        // CoreGraphics' origin is bottom-left; this puts the image's top-left at the top-left.
        context.draw(image, in: CGRect(x: 0, y: plan.height - image.height,
                                       width: image.width, height: image.height))
        guard let output = context.makeImage() else { return nil }
        return encode(output, dpi: plan.dpi)
    }

    static func decode(_ page: RawPage) -> CGImage? {
        switch page.format {
        case .jpeg:
            guard let source = CGImageSourceCreateWithData(page.data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .gray8:
            return grayImage(page.data, width: page.width)
        case .blackAndWhite:
            return grayImage(unpack(page.data), width: page.width / 8 * 8)
        }
    }

    /// Expands packed 1-bit rows (1 = black) to one byte per pixel (0 = black).
    static func unpack(_ packed: Data) -> Data {
        var out = Data(count: packed.count * 8)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var i = 0
            for byte in packed {
                for bit in 0..<8 {
                    dst[i] = byte & (0x80 >> UInt8(bit)) != 0 ? 0x00 : 0xFF
                    i += 1
                }
            }
        }
        return out
    }

    private static func grayImage(_ pixels: Data, width: Int) -> CGImage? {
        guard width > 0 else { return nil }
        let height = pixels.count / width
        guard height > 0, let provider = CGDataProvider(data: pixels.prefix(width * height) as CFData)
        else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func encode(_ image: CGImage, dpi: Int) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
