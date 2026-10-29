import AppKit

/// The menu bar icon: a short waveform turning into lines of text.
enum StatusIcon {
    static func image(alert: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let shift: CGFloat = alert ? -1.5 : 0
            // The waveform: four rounded bars of different heights.
            for (index, height) in [5.0, 10.0, 7.0, 3.5].enumerated() {
                let x = 2.5 + CGFloat(index) * 2.6 + shift
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: 1.7, height: height), xRadius: 0.85, yRadius: 0.85).fill()
            }
            // Then the words it became.
            for (index, width) in [6.5, 5.0, 6.5].enumerated() {
                let y = rect.midY + 3.2 - CGFloat(index) * 3.2 - 0.8
                NSBezierPath(roundedRect: NSRect(x: 12.4 + shift, y: y, width: width, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            }
            if alert {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5.5, y: rect.maxY - 6, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "Memo Export, needs attention" : "Memo Export"
        return image
    }
}
