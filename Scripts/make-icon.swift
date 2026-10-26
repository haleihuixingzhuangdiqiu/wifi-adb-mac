import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func render(_ size: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(size)
    let bounds = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let rounded = NSBezierPath(roundedRect: bounds, xRadius: s * 0.205, yRadius: s * 0.205)
    NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.21, blue: 0.29, alpha: 1), ending: NSColor(srgbRed: 0.04, green: 0.09, blue: 0.15, alpha: 1))!.draw(in: rounded, angle: -60)
    NSColor(srgbRed: 0.4, green: 0.95, blue: 0.8, alpha: 0.20).setStroke()
    rounded.lineWidth = max(1, s * 0.008)
    rounded.stroke()
    // Original vector artwork: no exported system-symbol or third-party image assets.
    NSColor(srgbRed: 0.4, green: 0.96, blue: 0.79, alpha: 1).setStroke()
    let phone = NSBezierPath(roundedRect: NSRect(x: s * 0.35, y: s * 0.20, width: s * 0.30, height: s * 0.60), xRadius: s * 0.055, yRadius: s * 0.055)
    phone.lineWidth = s * 0.025
    phone.stroke()
    for y in [0.74, 0.26] {
        let detail = NSBezierPath()
        detail.move(to: NSPoint(x: s * 0.46, y: s * y))
        detail.line(to: NSPoint(x: s * 0.54, y: s * y))
        detail.lineWidth = s * 0.02
        detail.lineCapStyle = .round
        detail.stroke()
    }
    for radius in [0.24, 0.32] {
        for (x, start, end) in [(0.50, 145.0, 215.0), (0.50, -35.0, 35.0)] {
            let wave = NSBezierPath()
            wave.appendArc(withCenter: NSPoint(x: s * x, y: s * 0.50), radius: s * radius, startAngle: start, endAngle: end)
            wave.lineWidth = s * 0.024
            wave.lineCapStyle = .round
            wave.stroke()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: directory.appendingPathComponent(name))
}
for base in [16, 32, 128, 256, 512] {
    try render(base, name: "icon_\(base)x\(base).png")
    try render(base * 2, name: "icon_\(base)x\(base)@2x.png")
}
