import AppKit

/// A 3.5mm plug, drawn rather than taken from SF Symbols.
///
/// macOS already shows the `headphones` glyph in Control Center and the volume menu,
/// so a second one in the menu bar reads as a system control. A plug is unambiguous,
/// and it depicts the thing the app actually acts on.
enum PlugIcon {

    /// Design box, origin bottom-left. Wider than tall, like the plug itself — forcing
    /// a long thin object into a square box just leaves it small and unreadable.
    private static let design = CGSize(width: 20, height: 14)

    static var aspectRatio: CGFloat { design.width / design.height }

    /// Fills the plug into `rect` using the current fill colour.
    /// `rect` is assumed to carry `aspectRatio`; callers scale it themselves.
    static func drawPlug(in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / design.width, y: rect.height / design.height)

        // Body, then shaft, as two fills. Letting them overlap is fine across separate
        // fills, whereas a single even-odd path would punch the overlap out into a hole.
        NSBezierPath(roundedRect: NSRect(x: 9.0, y: 4.2, width: 9.0, height: 5.6),
                     xRadius: 2.0, yRadius: 2.0).fill()

        let shaft = NSBezierPath(roundedRect: NSRect(x: 1.0, y: 5.9, width: 8.5, height: 2.2),
                                 xRadius: 1.1, yRadius: 1.1)
        // Insulator gaps, kept strictly inside the shaft so even-odd reads them as
        // holes rather than as extra ink.
        shaft.append(NSBezierPath(rect: NSRect(x: 3.4, y: 5.9, width: 0.9, height: 2.2)))
        shaft.append(NSBezierPath(rect: NSRect(x: 5.6, y: 5.9, width: 0.9, height: 2.2)))
        shaft.windingRule = .evenOdd
        shaft.fill()

        ctx.restoreGState()
    }

    /// Template image for the status item. Slashed when the button is disabled.
    static func menuBarImage(disabled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: design.width, height: design.height),
                            flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            drawPlug(in: rect)
            if disabled { strike(in: rect) }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Rounded-square app icon, used in Finder and in the Input Monitoring list.
    static func drawAppIcon(in rect: CGRect) {
        let body = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        let radius = body.width * 0.2237 // matches the macOS app icon corner
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(calibratedWhite: 0.30, alpha: 1),
                   ending: NSColor(calibratedWhite: 0.11, alpha: 1))?.draw(in: shape, angle: -90)

        // Fit the design box inside the icon without distorting it.
        NSColor.white.setFill()
        let width = body.width * 0.68
        let height = width / aspectRatio
        drawPlug(in: CGRect(x: body.midX - width / 2, y: body.midY - height / 2,
                            width: width, height: height))
    }

    /// Diagonal bar in the system's own "disabled" idiom: a cleared channel through the
    /// glyph, then the bar itself, so both stay legible at menu bar size.
    private static func strike(in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let scale = rect.width / design.width
        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        let line = NSBezierPath()
        line.move(to: point(2.2, 2.8))
        line.line(to: point(17.8, 11.2))
        line.lineCapStyle = .round

        ctx.compositingOperation = .destinationOut
        line.lineWidth = 3.0 * scale
        line.stroke()

        ctx.compositingOperation = .sourceOver
        line.lineWidth = 1.6 * scale
        line.stroke()
    }
}
