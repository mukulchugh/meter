import AppKit
import SwiftUI

/// Meter brand assets in code. Source of truth: brand/BRAND.md, brand/palette.json, brand/glyph/*.svg.
public enum Brand {
    /// Meter Petrol: the one accent. Light value on light surfaces, dark value on dark ones (palette.json).
    public static let accent = Color(nsColor: NSColor(name: "MeterPetrol") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x62 / 255.0, green: 0xD4 / 255.0, blue: 0xD2 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0x08 / 255.0, green: 0x7F / 255.0, blue: 0x82 / 255.0, alpha: 1)
    })

    /// The menu-bar gauge (brand/glyph/meter-glyph.svg) as an 18 pt template image, so the system tints
    /// it for light, dark and highlighted bars. `attention` adds the small mark from
    /// meter-glyph-attention.svg, used when data is stale, missing or a key fails.
    public static func glyph(attention: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // Arc: the ring segment between r 5.5 and r 7.5 around (9, 11.5), drawn as a 2 pt round-capped stroke.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 11.5), radius: 6.5, startAngle: 180, endAngle: 360, clockwise: false)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            arc.stroke()
            // Needle from the hub toward the upper right.
            let needle = NSBezierPath()
            needle.move(to: NSPoint(x: 9, y: 11.5))
            needle.line(to: NSPoint(x: 12.5, y: 7.5))
            needle.lineWidth = 1.7
            needle.lineCapStyle = .round
            needle.stroke()
            // Hub.
            NSBezierPath(ovalIn: NSRect(x: 7.5, y: 10, width: 3, height: 3)).fill()
            if attention {
                // Small exclamation mark at the lower right.
                let bar = NSBezierPath(roundedRect: NSRect(x: 14, y: 13.1, width: 1.5, height: 2.5), xRadius: 0.75, yRadius: 0.75)
                bar.fill()
                NSBezierPath(ovalIn: NSRect(x: 14, y: 16, width: 1.5, height: 1.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = attention ? "Meter, needs attention" : "Meter"
        return image
    }
}
