import AppKit

/// The one place that builds a real bordered `NSTextTable` grid, shared by `MarkdownRenderer`
/// (GFM tables) and `OfficeTextBuilder` (Word/office tables) — a table looks and behaves the same
/// however the document reached it. Each caller renders its own cell content (markdown inline
/// spans vs office `Span`s) into an `NSAttributedString` first; this only lays those strings into
/// `NSTextTableBlock` cells with border, padding and header shading.
enum TableBlockBuilder {
    /// - Parameters:
    ///   - rows: already-styled cell content, one `NSAttributedString` per cell. Rows may have
    ///     fewer cells than the widest row — a short row just leaves its trailing columns empty,
    ///     it does not shift or collapse.
    ///   - headerRows: how many LEADING rows are shaded/bold. `0` means none — a real contract can
    ///     be headerless, and shading row one anyway would misrepresent it (same reasoning
    ///     `OfficeTextBuilder.appendTable`'s doc comment gives for its own header handling).
    static func build(rows: [[NSAttributedString]], headerRows: Int, theme: RenderTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ncol = rows.map(\.count).max() ?? 0
        guard ncol > 0 else { return result }

        let textTable = NSTextTable()
        textTable.numberOfColumns = ncol
        textTable.setContentWidth(100, type: .percentageValueType)
        let cellLH = (theme.baseFontSize * 1.4).rounded()

        for (row, cells) in rows.enumerated() {
            let header = row < headerRows
            for col in 0..<ncol {
                let block = NSTextTableBlock(table: textTable, startingRow: row, rowSpan: 1,
                                             startingColumn: col, columnSpan: 1)
                block.setBorderColor(Palette.tableBorder)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(7, type: .absoluteValueType, for: .padding)
                if header { block.backgroundColor = Palette.tableHeaderBg }
                let ps = NSMutableParagraphStyle()
                ps.textBlocks = [block]
                ps.minimumLineHeight = cellLH
                ps.maximumLineHeight = cellLH
                let content = NSMutableAttributedString()
                if col < cells.count { content.append(cells[col]) }
                let font = header ? NSFont.systemFont(ofSize: theme.baseFontSize, weight: .semibold) : theme.bodyFont
                content.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                content.addAttribute(.paragraphStyle, value: ps,
                                     range: NSRange(location: 0, length: content.length))
                result.append(content)
            }
        }
        return result
    }
}
