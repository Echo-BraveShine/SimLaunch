import Foundation
import CoreGraphics
import ImageIO
import AppKit

enum IconRasterizer {
    static func image(_ data: Data) -> CGImage? {
        guard data.count > 0, data.count <= 2_097_152 else { return nil }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0, width <= 4096, height <= 4096, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) { return image }
        // AppKit can render SVG resources. Reject active content and external references first.
        guard let text = String(data: data, encoding: .utf8), text.contains("<svg"),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY"),
              !text.localizedCaseInsensitiveContains("<script"), !text.localizedCaseInsensitiveContains("foreignObject"),
              text.range(of: #"(?:href\s*=\s*["']\s*(?!#)|url\(\s*(?!#))"#, options: [.regularExpression, .caseInsensitive]) == nil,
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 128, height: 128)
        var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    static func normalized(_ data: Data) -> Data? { image(data).flatMap(png) }
    static func composite(background: Data, foreground: Data) -> Data? {
        guard let back = image(background), let front = image(foreground),
              let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        context.draw(back, in: rect); context.draw(front, in: rect)
        return context.makeImage().flatMap(png)
    }
}
