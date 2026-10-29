// Draws the app icon and writes it to Resources/AppIcon.icns, plus docs/icon.png for the website.
//
//   swift scripts/make-icon.swift
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

/// Draws the icon on a 1024-point canvas, scaled to `pixels`.
func icon(pixels: Int) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()

    let slate = NSColor(srgbRed: 0.13, green: 0.17, blue: 0.27, alpha: 1)
    let ice = NSColor(srgbRed: 0.62, green: 0.82, blue: 1.0, alpha: 1)

    // The rounded tile, with the soft shadow macOS icons sit on. Same tile and light as Show Desktop.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = .black.withAlphaComponent(0.3)
    tileShadow.shadowBlurRadius = 24
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    slate.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.80, green: 0.87, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.57, blue: 0.75, alpha: 1),
        slate,
    ])!.draw(in: tile, angle: -90)

    /// A rounded bar, with a soft shadow, or glowing in `color` when it's the newest part.
    func bar(_ rect: NSRect, color: NSColor, glow: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        if glow {
            shadow.shadowColor = color.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = 34
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -6)
        }
        shadow.set()
        color.setFill()
        let radius = min(rect.width, rect.height) / 2
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // A waveform on the left, its bars fading in from where the sound began, turning into lines
    // of text on the right. The last line, the newest words, glows in ice blue against the slate.
    let waves: [(height: CGFloat, alpha: CGFloat)] = [(150, 0.32), (300, 0.46), (420, 0.62), (250, 0.78), (130, 0.9)]
    for (index, wave) in waves.enumerated() {
        let x = 222 + CGFloat(index) * 68
        bar(NSRect(x: x, y: 512 - wave.height / 2, width: 40, height: wave.height), color: NSColor.white.withAlphaComponent(wave.alpha), glow: false)
    }
    let lines: [(y: CGFloat, width: CGFloat)] = [(632, 200), (552, 160), (472, 200), (392, 130)]
    for (index, line) in lines.enumerated() {
        let last = index == lines.count - 1
        bar(NSRect(x: 590, y: line.y - 20, width: line.width, height: 40), color: last ? ice : .white, glow: last)
    }

    NSGraphicsContext.restoreGraphicsState()
    return image
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = icon(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try icon(pixels: 256).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
Swift.print("Wrote \(output) and docs/icon.png")
