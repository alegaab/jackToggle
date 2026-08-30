import AppKit

// Writes an .iconset for iconutil. Compiled together with PlugIcon.swift so the
// Finder icon and the menu bar glyph can never drift apart.
@main
struct GenerateIcon {

    static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func main() throws {
        let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./JackToggle.iconset"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

        for variant in variants {
            // Drawing into an explicitly sized bitmap rep, rather than an NSImage,
            // keeps the output at exactly the pixel dimensions iconutil expects.
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: variant.pixels, pixelsHigh: variant.pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            PlugIcon.drawAppIcon(in: CGRect(x: 0, y: 0, width: variant.pixels, height: variant.pixels))
            NSGraphicsContext.restoreGraphicsState()

            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: "\(output)/\(variant.name).png"))
        }
    }
}
