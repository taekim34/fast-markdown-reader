import AppKit

/// Turns a format-neutral `[OfficeBlock]` into styled `NSAttributedString`, the same way
/// `MarkdownRenderer` turns a parsed markdown tree into one and `PlainTextRenderer` turns raw text
/// into one. Every TOP-LEVEL block is exactly one navigation stop: it gets its own `MDAttr.blockId`
/// over its full rendered range (content + its one trailing separator), so gutter click / block
/// edit work here for free once a later sprint wires this into the document — see invariant 1's
/// sibling rule for images: a reserved layout size must never depend on whether pixels are loaded.
enum OfficeTextBuilder {
    static func build(_ blocks: [OfficeBlock], theme: RenderTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var blockSeq = 0
        // Ordered-list numbering state, keyed by nesting level. Lives for the whole build() call
        // (not per-block) because the restart rule below needs to see across blocks.
        var orderedCounters: [Int: Int] = [:]

        func tagBlock(from start: Int) {
            let r = NSRange(location: start, length: result.length - start)
            guard r.length > 0 else { return }
            result.addAttribute(MDAttr.blockId, value: blockSeq, range: r)
            blockSeq += 1
        }

        for block in blocks {
            let start = result.length
            switch block {
            case let .heading(level, spans):
                result.append(spansAttributedString(spans, baseFont: theme.headingFont(level: level),
                                                     baseColor: theme.textColor, theme: theme))
                // Tagged BEFORE the trailing newline is appended, so a substring of this range is
                // exactly the heading's text — precisely what the outline sidebar reads
                // (`OutlinePanel.reload` trims and shows it verbatim).
                result.addAttribute(MDAttr.heading, value: level,
                                     range: NSRange(location: start, length: result.length - start))
                result.append(NSAttributedString(string: "\n"))
                result.addAttribute(.paragraphStyle, value: headingParagraphStyle(level: level, theme: theme),
                                     range: NSRange(location: start, length: result.length - start))

            case let .paragraph(spans):
                result.append(spansAttributedString(spans, baseFont: theme.bodyFont,
                                                     baseColor: theme.textColor, theme: theme))
                result.append(NSAttributedString(string: "\n"))
                result.addAttribute(.paragraphStyle, value: bodyParagraphStyle(theme: theme),
                                     range: NSRange(location: start, length: result.length - start))

            case let .listItem(level, ordered, spans):
                appendListItem(level: level, ordered: ordered, spans: spans, into: result,
                                theme: theme, orderedCounters: &orderedCounters)

            case let .table(rows, headerRows):
                appendTable(rows, headerRows: headerRows, into: result, theme: theme)

            case let .image(id, size):
                appendImage(id: id, size: size, into: result)
            }
            tagBlock(from: start)
        }
        return result
    }

    // MARK: Spans → attributed runs

    /// Renders one block's spans against that block's base font/color. A `code` span overrides
    /// BOTH with the theme's inline-code styling and tags `MDAttr.inlineCode` — bold/italic/
    /// underline still layer on top of it (an office run can be monospaced AND bold at once,
    /// unlike a markdown code span, which never carries emphasis).
    ///
    /// NOT private: a later sprint's RTF reader re-themes spans it parsed itself rather than
    /// receiving as `OfficeBlock`, and needs this exact styling logic rather than a duplicate.
    static func spansAttributedString(_ spans: [Span], baseFont: NSFont, baseColor: NSColor,
                                      theme: RenderTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            var font = baseFont
            var color = baseColor
            var attrs: [NSAttributedString.Key: Any] = [:]
            if span.code {
                font = theme.codeFont
                color = theme.inlineCodeColor
                attrs[MDAttr.inlineCode] = true
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if span.bold { traits.insert(.bold) }
            if span.italic { traits.insert(.italic) }
            if !traits.isEmpty { font = fontAdding(traits, to: font) }
            attrs[.font] = font
            attrs[.foregroundColor] = color
            if span.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        return out
    }

    /// Adds symbolic traits while keeping the SAME family, so vertical metrics (ascent/descent)
    /// don't shift — an unrelated bold face would jitter the baseline under a fixed line height
    /// (same reasoning as `MarkdownRenderer.fontAdding`, duplicated here: that one is private to
    /// its file).
    private static func fontAdding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    // MARK: Paragraph styles

    private static func bodyParagraphStyle(theme: RenderTheme) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * 1.45).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = theme.baseFontSize * 0.9
        return p.copy() as! NSParagraphStyle
    }

    private static func headingParagraphStyle(level: Int, theme: RenderTheme) -> NSParagraphStyle {
        let b = theme.baseFontSize
        let p = NSMutableParagraphStyle()
        let lh = (theme.headingSize(level: level) * 1.25).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = b * 0.4
        p.paragraphSpacingBefore = b * (level <= 2 ? 1.9 : 1.4)
        return p.copy() as! NSParagraphStyle
    }

    // MARK: Lists

    /// Bullet glyph per depth so nested levels read distinctly: • → ◦ → ▪ (then repeat) — same
    /// progression `MarkdownRenderer.bullet(_:)` uses.
    private static func bulletGlyph(_ level: Int) -> String {
        switch level % 3 {
        case 0:  return "•"
        case 1:  return "◦"
        default: return "▪"
        }
    }

    /// Hanging-indent paragraph style: marker at `markerX`, a tab pushes text to `textX`, and
    /// wrapped lines align at `textX` — so the item's first line and every wrap share one edge.
    private static func listParagraphStyle(markerX: CGFloat, textX: CGFloat, theme: RenderTheme) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * 1.45).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = theme.baseFontSize * 0.3
        p.firstLineHeadIndent = markerX
        p.headIndent = textX
        p.tabStops = [NSTextTab(textAlignment: .left, location: textX)]
        p.defaultTabInterval = textX
        return p.copy() as! NSParagraphStyle
    }

    /// Renders one list item and updates the per-level numbering state.
    ///
    /// Restart rule (the only stateful part of this file): any item at `level` clears the counters
    /// of every level DEEPER than it — a shallower-or-equal item breaks a deeper level's run, so
    /// that level restarts at 1 the next time it appears. A deeper level intervening does NOT
    /// clear a shallower level's own counter, so `1. / a. / b. / 2.` keeps counting `1, 2` at the
    /// outer level across the nested run. An UNORDERED item also clears its OWN level's counter,
    /// so a bullet breaks an ordered run at that same level too.
    private static func appendListItem(level: Int, ordered: Bool, spans: [Span],
                                       into result: NSMutableAttributedString, theme: RenderTheme,
                                       orderedCounters: inout [Int: Int]) {
        // Snapshot the keys first — removing while iterating `.keys` directly mutates the same
        // storage the view is walking.
        for deeper in orderedCounters.keys.filter({ $0 > level }) {
            orderedCounters.removeValue(forKey: deeper)
        }
        let marker: String
        if ordered {
            let n = (orderedCounters[level] ?? 0) + 1
            orderedCounters[level] = n
            marker = "\(n).\t"
        } else {
            orderedCounters.removeValue(forKey: level)
            marker = bulletGlyph(level) + "\t"
        }

        let hang = theme.baseFontSize * 1.7
        let markerX = CGFloat(level) * hang
        let textX = CGFloat(level + 1) * hang
        let start = result.length
        result.append(NSAttributedString(string: marker,
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.textColor]))
        result.append(spansAttributedString(spans, baseFont: theme.bodyFont, baseColor: theme.textColor, theme: theme))
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle, value: listParagraphStyle(markerX: markerX, textX: textX, theme: theme),
                            range: NSRange(location: start, length: result.length - start))
    }

    // MARK: Tables

    /// A tab-stop grid, not a real bordered table (`NSTextTable`, which `MarkdownRenderer` uses) —
    /// `OfficeBlock` doesn't carry per-cell borders/merges, and a hand-rolled grid is enough to
    /// read as a table: `Palette.tableHeaderBg` shades the leading `headerRows` rows, and
    /// `Palette.tableBorder` underlines the LAST of them (the header/body boundary) — `headerRows:
    /// 0` means none of that: every row renders as ordinary content, because the source didn't say
    /// any row was a header (see `OfficeBlock.table`; guessing "row one" would misrepresent a
    /// headerless table). A cell always gets its tab even when empty, so an empty cell leaves its
    /// column in place instead of collapsing the row.
    private static func appendTable(_ rows: [[[Span]]], headerRows: Int, into result: NSMutableAttributedString,
                                    theme: RenderTheme) {
        let ncol = rows.map(\.count).max() ?? 0
        guard ncol > 0 else {
            result.append(NSAttributedString(string: "\n"))
            return
        }
        let colWidth = theme.baseFontSize * 6
        let tabStops = (1...ncol).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * colWidth) }
        let headerFont = fontAdding(.bold, to: theme.bodyFont)
        let lineHeight = (theme.baseFontSize * 1.4).rounded()

        for (r, row) in rows.enumerated() {
            let isHeader = r < headerRows
            let rowStart = result.length
            for col in 0..<ncol {
                let cellSpans = col < row.count ? row[col] : []
                result.append(spansAttributedString(cellSpans, baseFont: isHeader ? headerFont : theme.bodyFont,
                                                     baseColor: theme.textColor, theme: theme))
                if col < ncol - 1 { result.append(NSAttributedString(string: "\t")) }
            }
            result.append(NSAttributedString(string: "\n"))
            let ps = NSMutableParagraphStyle()
            ps.minimumLineHeight = lineHeight
            ps.maximumLineHeight = lineHeight
            ps.tabStops = tabStops
            ps.defaultTabInterval = colWidth
            let rowRange = NSRange(location: rowStart, length: result.length - rowStart)
            result.addAttribute(.paragraphStyle, value: ps, range: rowRange)
            if isHeader {
                result.addAttribute(.backgroundColor, value: Palette.tableHeaderBg, range: rowRange)
                if r == headerRows - 1 {
                    result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: rowRange)
                    result.addAttribute(.underlineColor, value: Palette.tableBorder, range: rowRange)
                }
            }
        }
    }

    // MARK: Images

    /// Reserves EXACTLY `size` via `SizedAttachmentCell`, image left `nil` — pixels arrive in a
    /// later sprint. This is invariant 1 of this codebase: the reserved layout size must NEVER
    /// depend on whether an image is loaded, or the scroll bar swings when it loads/purges.
    private static func appendImage(id: String, size: CGSize, into result: NSMutableAttributedString) {
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: size)
        att.attachmentCell = SizedAttachmentCell(reservedSize: size)
        let ph = NSMutableAttributedString(attachment: att)
        ph.addAttribute(MDAttr.image, value: id, range: NSRange(location: 0, length: ph.length))
        result.append(ph)
        result.append(NSAttributedString(string: "\n"))
    }
}
