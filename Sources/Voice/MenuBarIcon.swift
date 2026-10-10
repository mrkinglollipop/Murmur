import AppKit

/// The menu-bar status glyph: Murmur's waveform, drawn as a template image so
/// it follows the menu bar's appearance. A stock microphone symbol is
/// indistinguishable from every other dictation app's.
enum MenuBarIcon: Equatable {
    case idle
    case listening
    case processing
    case paused
    case error

    static let pointSize: CGFloat = 18

    /// Bar heights in points, leading to trailing. Paused is a flat line.
    static func barHeights(for icon: MenuBarIcon) -> [CGFloat] {
        switch icon {
        case .idle, .listening, .processing:
            return [3.75, 8.25, 12.75, 6.75, 10.5, 4.5]
        case .paused:
            return [2.25, 2.25, 2.25, 2.25, 2.25, 2.25]
        case .error:
            return [3.75, 8.25, 12.75, 6.75]
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .paused: return "Murmur, paused"
        case .error: return "Murmur — error"
        case .idle, .listening, .processing: return "Murmur"
        }
    }

    var image: NSImage {
        let icon = self
        let side = Self.pointSize
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let heights = Self.barHeights(for: icon)
            let barWidth: CGFloat = icon == .listening ? 1.5 : 1.8
            let gap: CGFloat = icon == .listening ? 1.0 : 1.2
            let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            // The error glyph keeps its bars to the leading side for the cross.
            let startX = icon == .error ? 1.0 : (rect.width - total) / 2
            let bars = NSBezierPath()
            for (index, height) in heights.enumerated() {
                let x = startX + CGFloat(index) * (barWidth + gap)
                let bar = NSRect(x: x, y: (rect.height - height) / 2, width: barWidth, height: height)
                bars.appendRoundedRect(bar, xRadius: barWidth / 2, yRadius: barWidth / 2)
            }
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch icon {
            case .listening:
                // Filled plate with the bars knocked out.
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4.5, yRadius: 4.5).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                bars.fill()
            case .processing:
                NSColor.black.withAlphaComponent(0.5).setFill()
                bars.fill()
            case .error:
                bars.fill()
                let cross = NSBezierPath()
                cross.lineWidth = 1.6
                cross.lineCapStyle = .round
                cross.move(to: NSPoint(x: 13, y: 2.5))
                cross.line(to: NSPoint(x: 17, y: 6.5))
                cross.move(to: NSPoint(x: 17, y: 2.5))
                cross.line(to: NSPoint(x: 13, y: 6.5))
                cross.stroke()
            case .idle, .paused:
                bars.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
