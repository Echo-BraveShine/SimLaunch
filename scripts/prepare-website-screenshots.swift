#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Preserve the real screenshot and clip only the area outside its window outline.
// Geometry uses source pixels with a top-left origin. No UI is redrawn or resized.
// Current 2× capture profile: devices 852×1282, settings 1760×1296.
// Capture all four locale/appearance variants before converting:
//
// swiftc scripts/prepare-website-screenshots.swift -o /tmp/simlaunch-prepare-screenshots
// for variant in zh-light zh-dark en-light en-dark; do
//   /tmp/simlaunch-prepare-screenshots "/tmp/simlaunch-website-raw/devices-${variant}.jpg" \
//     "website/assets/devices-${variant}.png" --kind devices \
//     --crop 26,7,800,1249 --radius 22 --arrow 399.5,60,19 --inset 1
//   /tmp/simlaunch-prepare-screenshots "/tmp/simlaunch-website-raw/settings-${variant}.jpg" \
//     "website/assets/settings-${variant}.png" --kind settings \
//     --crop 0,56,1760,1240 --radius 28 --inset 1
// done
// sips -g hasAlpha website/assets/{devices,settings}-{zh,en}-{light,dark}.png
// python3 scripts/check-website.py
//
// Re-measure geometry if the app size or display scale changes. The settings crop
// excludes only the system title bar; keep cursors and click glows outside it.
let usage = """
Usage: swift scripts/prepare-website-screenshots.swift INPUT OUTPUT.png \
  --kind settings|devices --radius PIXELS \
  [--crop X,Y,WIDTH,HEIGHT] [--arrow CENTER_X,WIDTH,HEIGHT] [--inset PIXELS]

--crop   Crop to the window bounds, including its arrow if present (integer pixels).
--radius Native window/body corner radius within the cropped image.
--arrow  Devices only: keep the native rounded popover arrow above its body. Coordinates
         are relative to the cropped image; body starts at the given arrow height.
--inset  Optional small inward mask adjustment for a captured JPEG's white fringe.
         This does not change output dimensions. Default: 0.
"""

struct ScreenshotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func numbers(_ value: String, count: Int, option: String) throws -> [CGFloat] {
    let result = value.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0) }
    guard result.count == count, result.allSatisfy({ $0.isFinite }) else {
        throw ScreenshotError("\(option) expects \(count) finite comma-separated numbers")
    }
    return result.map { CGFloat($0) }
}

func prepare() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") { print(usage); return }
    guard args.count >= 2 else { throw ScreenshotError(usage) }
    let input = URL(fileURLWithPath: args[0]).standardizedFileURL
    let output = URL(fileURLWithPath: args[1]).standardizedFileURL
    guard input != output, output.pathExtension.lowercased() == "png" else {
        throw ScreenshotError("Use a separate .png output file; the source capture is never overwritten")
    }
    var options: [String: String] = [:]
    var index = 2
    let allowed: Set<String> = ["--kind", "--radius", "--crop", "--arrow", "--inset"]
    while index < args.count {
        let key = args[index]
        guard allowed.contains(key), index + 1 < args.count, options[key] == nil else {
            throw ScreenshotError("Unknown, duplicate, or incomplete option: \(key)\n\(usage)")
        }
        options[key] = args[index + 1]
        index += 2
    }
    guard let kind = options["--kind"], ["settings", "devices"].contains(kind), let radiusValue = options["--radius"] else {
        throw ScreenshotError("Specify --kind settings|devices and the measured --radius\n\(usage)")
    }
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ScreenshotError("Cannot read source screenshot: \(input.path)")
    }
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
        throw ScreenshotError("Source must be an upright screenshot (EXIF orientation 1)")
    }
    let sourceBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var crop = sourceBounds
    if let value = options["--crop"] {
        let values = try numbers(value, count: 4, option: "--crop")
        guard values.allSatisfy({ $0.rounded() == $0 }) else {
            throw ScreenshotError("--crop uses integer source pixels")
        }
        crop = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard crop.width > 0, crop.height > 0, sourceBounds.contains(crop) else {
            throw ScreenshotError("Crop lies outside source dimensions \(image.width)×\(image.height)")
        }
    }
    guard let cropped = image.cropping(to: crop) else { throw ScreenshotError("Cannot crop screenshot") }
    let width = CGFloat(cropped.width), height = CGFloat(cropped.height)
    let radius = try numbers(radiusValue, count: 1, option: "--radius")[0]
    let inset = try numbers(options["--inset"] ?? "0", count: 1, option: "--inset")[0]
    var arrow: [CGFloat]?
    if let value = options["--arrow"] {
        guard kind == "devices" else { throw ScreenshotError("--arrow is only valid for devices") }
        arrow = try numbers(value, count: 3, option: "--arrow")
    }
    let arrowHeight = arrow?[2] ?? 0
    let body = CGRect(x: inset, y: inset, width: width - 2 * inset, height: height - arrowHeight - 2 * inset)
    guard inset >= 0, body.width > 0, body.height > 0, radius >= 0,
          radius <= min(body.width, body.height) / 2 else { throw ScreenshotError("Invalid radius, inset, or body size") }
    let outline = CGMutablePath()
    outline.addRoundedRect(in: body, cornerWidth: radius, cornerHeight: radius)
    if let arrow {
        let (center, halfWidth) = (arrow[0], arrow[1] / 2)
        guard arrowHeight > 0, arrow[1] > 0,
              center - halfWidth >= body.minX + radius,
              center + halfWidth <= body.maxX - radius else { throw ScreenshotError("Arrow must fit on the body's straight top edge") }
        let top = height - inset
        let shoulder = body.maxY + arrowHeight * 0.68
        // The system arrow has a rounded tip and a curved join to the flat top.
        // Cubic curves preserve that outline instead of imposing a pointed triangle.
        outline.move(to: CGPoint(x: center - halfWidth, y: body.maxY))
        outline.addCurve(to: CGPoint(x: center - halfWidth * 0.32, y: shoulder),
            control1: CGPoint(x: center - halfWidth * 0.63, y: body.maxY),
            control2: CGPoint(x: center - halfWidth * 0.50, y: body.maxY + arrowHeight * 0.46))
        outline.addCurve(to: CGPoint(x: center, y: top),
            control1: CGPoint(x: center - halfWidth * 0.24, y: body.maxY + arrowHeight * 0.90),
            control2: CGPoint(x: center - halfWidth * 0.15, y: top))
        outline.addCurve(to: CGPoint(x: center + halfWidth * 0.32, y: shoulder),
            control1: CGPoint(x: center + halfWidth * 0.15, y: top),
            control2: CGPoint(x: center + halfWidth * 0.24, y: body.maxY + arrowHeight * 0.90))
        outline.addCurve(to: CGPoint(x: center + halfWidth, y: body.maxY),
            control1: CGPoint(x: center + halfWidth * 0.50, y: body.maxY + arrowHeight * 0.46),
            control2: CGPoint(x: center + halfWidth * 0.63, y: body.maxY))
        outline.closeSubpath()
    }
    let colorSpace = cropped.colorSpace?.model == .rgb ? cropped.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
        bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw ScreenshotError("Cannot allocate RGBA screenshot")
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.addPath(outline)
    context.clip()
    context.interpolationQuality = .none
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw ScreenshotError("Cannot create masked screenshot") }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ScreenshotError("Cannot create PNG: \(output.path)")
    }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { throw ScreenshotError("Cannot write PNG") }
    print("\(output.lastPathComponent): \(cropped.width)×\(cropped.height), radius \(radius), transparent window outline")
}

do {
    try prepare()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
