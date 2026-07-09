import AppKit

struct RenderTheme {
    var baseFontSize: CGFloat

    static func current(size: CGFloat) -> RenderTheme { RenderTheme(baseFontSize: size) }

    func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize * 1.9
        case 2: return baseFontSize * 1.5
        case 3: return baseFontSize * 1.25
        default: return baseFontSize * 1.1
        }
    }
    var bodyFont: NSFont { .systemFont(ofSize: baseFontSize) }
    var codeFont: NSFont { .monospacedSystemFont(ofSize: baseFontSize * 0.92, weight: .regular) }
    var textColor: NSColor { .textColor }
    var secondaryColor: NSColor { .secondaryLabelColor }
    var codeBackground: NSColor { NSColor.textColor.withAlphaComponent(0.06) }
}
