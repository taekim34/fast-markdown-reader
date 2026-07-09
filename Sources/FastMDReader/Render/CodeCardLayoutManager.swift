import AppKit

/// Draws each fenced code block as a distinct rounded "card" (fill + hairline border)
/// behind its text, instead of a flat background tint. Text stays selectable and
/// syntax-highlighted; only the backdrop changes. Card metrics are shared with the
/// copy-button overlay via `CodeCardMetrics` so the button lands on the card's edge.
enum CodeCardMetrics {
    static let horizontalMargin: CGFloat = 4   // gap from the text-area edges
    static let verticalPadding: CGFloat = 7    // extra height above/below the code text
    static let cornerRadius: CGFloat = 7
    static let textInset: CGFloat = 14         // left/right padding of code inside the card
}

final class CodeCardLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let m = CodeCardMetrics.self
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fill = NSColor.textColor.withAlphaComponent(0.045)
        let border = NSColor.textColor.withAlphaComponent(0.11)

        storage.enumerateAttribute(MDAttr.codeBlock, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let gr = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = self.boundingRect(forGlyphRange: gr, in: container)
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            var card = rect
            card.origin.x = origin.x + m.horizontalMargin
            card.size.width = container.size.width - m.horizontalMargin * 2
            card.origin.y -= m.verticalPadding
            card.size.height += m.verticalPadding * 2
            let path = NSBezierPath(roundedRect: card, xRadius: m.cornerRadius, yRadius: m.cornerRadius)
            fill.setFill(); path.fill()
            border.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}
