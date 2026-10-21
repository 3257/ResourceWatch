import AppKit
import Foundation

// Original vector artwork. Rebuild every macOS icon size without external tools/assets.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform(); scale.scale(by: CGFloat(pixels) / 1024); scale.concat()
    let rect = NSRect(x: 56, y: 56, width: 912, height: 912)
    let tile = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
    tile.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.025, green: 0.07, blue: 0.14, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.28, blue: 0.43, alpha: 1))!.draw(in: rect, angle: 90)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 7, dy: 7), xRadius: 199, yRadius: 199)
    border.lineWidth = 10; border.stroke()

    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 188, y: 500))
    pulse.line(to: NSPoint(x: 305, y: 500))
    pulse.line(to: NSPoint(x: 381, y: 677))
    pulse.line(to: NSPoint(x: 466, y: 341))
    pulse.line(to: NSPoint(x: 544, y: 572))
    pulse.line(to: NSPoint(x: 604, y: 500))
    pulse.line(to: NSPoint(x: 676, y: 500))
    pulse.lineWidth = pixels <= 32 ? 56 : 44
    pulse.lineJoinStyle = .round; pulse.lineCapStyle = .round
    NSColor.white.setStroke(); pulse.stroke()
    NSColor(srgbRed: 1, green: 0.30, blue: 0.32, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 740, y: 449, width: 102, height: 102)).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}

for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 1 ? "" : "@2x"
        try render(size * factor).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try render(1024).write(to: output.appendingPathComponent("AppIcon.png"))
// Icon Services/Notification Center can use the named asset, independently of
// Finder's legacy ICNS lookup. Supply both forms from the same original artwork.
let catalog = output.appendingPathComponent("Assets.xcassets", isDirectory: true)
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
let catalogInfo: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalogInfo, options: [.prettyPrinted, .sortedKeys]).write(to: catalog.appendingPathComponent("Contents.json"))
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 1 ? "" : "@2x"
        let name = "icon_\(size)x\(size)\(suffix).png"
        try Data(contentsOf: iconset.appendingPathComponent(name)).write(to: appIcon.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(factor)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: appIcon.appendingPathComponent("Contents.json"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
print("Generated original pulse/status-dot app icon")
