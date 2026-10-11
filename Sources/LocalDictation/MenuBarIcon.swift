import AppKit

/// The logo's five-bar waveform, drawn for the menu bar.
enum MenuBarIcon {
    enum State { case idle, recording, processing }

    /// Same proportions as the app icon (scripts/make-icon.swift).
    private static let barHeights: [CGFloat] = [0.22, 0.42, 0.68, 0.42, 0.22]

    static func image(_ state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = switch state {
            case .idle: .black
            case .recording: .systemRed
            case .processing: .systemBlue
            }
            color.setFill()
            let barWidth: CGFloat = 2.2
            let gap: CGFloat = 1.5
            let total = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
            var x = rect.midX - total / 2
            for h in barHeights {
                // Scale so the tallest bar fills most of the 18 pt height.
                let height = max(barWidth, rect.height * h / 0.68 * 0.85)
                let bar = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        // Template images follow the menu bar's light/dark appearance automatically.
        image.isTemplate = state == .idle
        image.accessibilityDescription = "Local Dictation"
        return image
    }
}
