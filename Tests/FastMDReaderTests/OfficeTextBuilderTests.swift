import XCTest
import AppKit
@testable import FastMDReader

final class OfficeTextBuilderTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    private func span(_ text: String, bold: Bool = false, italic: Bool = false,
                       underline: Bool = false, code: Bool = false) -> Span {
        Span(text: text, bold: bold, italic: italic, underline: underline, code: code)
    }

    private func build(_ blocks: [OfficeBlock]) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: theme)
    }

    /// One marker string ("1.", "2.", "•", …) per list-item block, read up to its first tab, in
    /// document order — enumerated the same way the reading cursor / gutter click would.
    private func listMarkers(in out: NSAttributedString) -> [String] {
        var markers: [String] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value is Int else { return }
            let line = out.attributedSubstring(from: range).string
            guard let tab = line.firstIndex(of: "\t") else { return }
            markers.append(String(line[line.startIndex..<tab]))
        }
        return markers
    }

    // MARK: Empty input

    func testEmptyBlockArrayReturnsEmptyAttributedStringWithoutCrashing() {
        let out = build([])
        XCTAssertEqual(out.length, 0)
        XCTAssertEqual(out.string, "")
    }

    // MARK: Block ids

    /// Every top-level block — regardless of kind — is exactly one navigation stop with a
    /// distinct, 0-based, monotonically increasing id over a non-empty range. A zero-length tag
    /// would be invisible to the reading cursor and gutter click (invariant carried over from
    /// `MarkdownRenderer`/`PlainTextRenderer`).
    func testEachBlockGetsADistinctMonotonicBlockIdOverANonEmptyRange() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("Title")]),
            .paragraph(spans: [span("Body")]),
            .listItem(level: 0, ordered: false, spans: [span("Item")]),
            .table(rows: [[[span("A")], [span("B")]]], headerRows: 0),
            .image(id: "img1", size: CGSize(width: 100, height: 80)),
        ]
        let out = build(blocks)
        var ids: [Int] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let id = value as? Int else { return }
            XCTAssertGreaterThan(range.length, 0, "block \(id) has a zero-length tag")
            ids.append(id)
        }
        XCTAssertEqual(ids, Array(0..<blocks.count), "ids must be 0-based, distinct and in document order")
    }

    /// A block with no spans at all (an empty paragraph) still renders SOMETHING (its separator),
    /// so it still gets a non-empty, distinct id — it must not be silently dropped from navigation.
    func testABlockWithNoSpansStillGetsItsOwnNonEmptyBlockId() {
        let out = build([.paragraph(spans: []), .paragraph(spans: [span("next")])])
        var ids: [Int] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let id = value as? Int else { return }
            XCTAssertGreaterThan(range.length, 0)
            ids.append(id)
        }
        XCTAssertEqual(ids, [0, 1])
    }

    // MARK: Heading outline (what OutlinePanel.reload does)

    func testHeadingAttributeEnumeratesLevelsInDocumentOrder() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("One")]),
            .paragraph(spans: [span("body text")]),
            .heading(level: 3, spans: [span("Three")]),
            .heading(level: 2, spans: [span("Two")]),
        ]
        let out = build(blocks)
        var levels: [Int] = []
        out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            guard let level = value as? Int else { return }
            levels.append(level)
        }
        XCTAssertEqual(levels, [1, 3, 2])
    }

    /// `OutlinePanel.reload` trims the tagged range and shows it as the entry title — the heading
    /// range must be exactly the heading's own text, not swallow the paragraph after it.
    func testHeadingRangeCoversOnlyItsOwnText() {
        let out = build([.heading(level: 2, spans: [span("Section")]), .paragraph(spans: [span("prose")])])
        var title: String?
        out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value != nil else { return }
            title = out.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(title, "Section")
    }

    // MARK: Fonts

    func testHeadingLevel1UsesThemeHeadingFont() {
        let out = build([.heading(level: 1, spans: [span("Title")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, theme.headingFont(level: 1).pointSize)
    }

    func testParagraphUsesThemeBodyFont() {
        let out = build([.paragraph(spans: [span("hello")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, theme.bodyFont.pointSize)
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: Spans

    /// Bold must land on exactly the bold span's characters — not bleed into its neighbours.
    func testBoldAppliesOnlyToTheBoldSpansRange() {
        let out = build([.paragraph(spans: [span("plain "), span("bold", bold: true), span(" tail")])])
        let text = out.string as NSString
        let boldRange = text.range(of: "bold")
        let plainFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let boldFont = out.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let tailFont = out.attribute(.font, at: boldRange.location + boldRange.length, effectiveRange: nil) as? NSFont
        XCTAssertFalse(plainFont!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(boldFont!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(tailFont!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testItalicAndUnderlineAreIndependentOfBold() {
        let out = build([.paragraph(spans: [span("slanted", italic: true), span("lined", underline: true)])])
        let text = out.string as NSString
        let italicRange = text.range(of: "slanted")
        let underlineRange = text.range(of: "lined")
        let italicFont = out.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(italicFont!.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(italicFont!.fontDescriptor.symbolicTraits.contains(.bold))
        let underlineValue = out.attribute(.underlineStyle, at: underlineRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(underlineValue, NSUnderlineStyle.single.rawValue)
    }

    /// `code` overrides font/color to the theme's inline-code styling and tags `MDAttr.inlineCode`
    /// — same contract `MarkdownRenderer` uses for the layout manager's chip background.
    func testCodeSpanUsesInlineCodeStylingAndIsTagged() {
        let out = build([.paragraph(spans: [span("snippet", code: true)])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(font?.pointSize, theme.codeFont.pointSize)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(color, theme.inlineCodeColor)
        XCTAssertNotNil(out.attribute(MDAttr.inlineCode, at: 0, effectiveRange: nil))
    }

    /// `spansAttributedString` must stay reachable from other files in this module — a later
    /// sprint's RTF reader re-themes spans it parsed itself, not `OfficeBlock`s. This call is the
    /// regression guard: it fails to COMPILE if the method goes back to `private`.
    func testSpansAttributedStringIsCallableFromOutsideThisType() {
        let out = OfficeTextBuilder.spansAttributedString([span("hi", bold: true)], baseFont: theme.bodyFont,
                                                           baseColor: theme.textColor, theme: theme)
        XCTAssertEqual(out.string, "hi")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: Lists — indent

    func testNestedListIndentIncreasesStrictlyWithLevel() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("top")]),
            .listItem(level: 1, ordered: true, spans: [span("nested")]),
            .listItem(level: 2, ordered: true, spans: [span("deeper")]),
        ]
        let out = build(blocks)
        var indents: [CGFloat] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value is Int else { return }
            let ps = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            indents.append(ps!.headIndent)
        }
        XCTAssertEqual(indents.count, 3)
        XCTAssertLessThan(indents[0], indents[1])
        XCTAssertLessThan(indents[1], indents[2])
    }

    // MARK: Lists — ordered numbering restart

    /// The brief's required case: after a deeper nested run, the OUTER level's numbering must
    /// still come out correct — i.e. it keeps counting (1, 2), not reset by the nested items.
    func testOrderedNumberingAfterADeeperLevelContinuesTheOuterCount() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("a")]),
            .listItem(level: 1, ordered: true, spans: [span("a-1")]),
            .listItem(level: 1, ordered: true, spans: [span("a-2")]),
            .listItem(level: 0, ordered: true, spans: [span("b")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "1.", "2.", "2."])
    }

    /// A SHALLOWER level intervening breaks the deeper level's run: level 1 must restart at "1."
    /// once a level-0 item has appeared in between.
    func testOrderedNumberingRestartsAfterAShallowerLevelIntervenes() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 1, ordered: true, spans: [span("x-1")]),
            .listItem(level: 1, ordered: true, spans: [span("x-2")]),
            .listItem(level: 0, ordered: true, spans: [span("shallow")]),
            .listItem(level: 1, ordered: true, spans: [span("y-1")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "2.", "1.", "1."])
    }

    /// An unordered item breaks an ordered run at the SAME level too.
    func testOrderedNumberingRestartsAfterABulletAtTheSameLevel() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("one")]),
            .listItem(level: 0, ordered: false, spans: [span("bullet")]),
            .listItem(level: 0, ordered: true, spans: [span("restarted")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "•", "1."])
    }

    func testUnorderedListUsesABulletNotANumber() {
        let out = build([.listItem(level: 0, ordered: false, spans: [span("item")])])
        XCTAssertEqual(listMarkers(in: out), ["•"])
    }

    // MARK: Tables

    /// A 2x2 table where one cell is empty must keep both rows at the same column count — the
    /// empty cell still leaves its tab, it doesn't collapse the row. `headerRows: 1` is today's
    /// asserted shape behaviour, kept as-is.
    func testTableWithHeaderRowAndAnEmptyCellKeepsItsRowAndColumnShape() {
        let rows: [[[Span]]] = [
            [[span("Name")], [span("Score")]],
            [[], [span("42")]],
        ]
        let out = build([.table(rows: rows, headerRows: 1)])
        let lines = out.string.split(separator: "\n", omittingEmptySubsequences: false)
        let headerCells = String(lines[0]).components(separatedBy: "\t")
        let bodyCells = String(lines[1]).components(separatedBy: "\t")
        XCTAssertEqual(headerCells, ["Name", "Score"])
        XCTAssertEqual(bodyCells.count, 2, "the empty first cell must still leave its column tab")
        XCTAssertEqual(bodyCells[0], "")
        XCTAssertEqual(bodyCells[1], "42")
    }

    /// Same shape guarantee with NO header row at all — a headerless table (the common case in the
    /// real contract test set) must not collapse a column just because row 0 isn't styled.
    func testTableWithNoHeaderAndAnEmptyCellKeepsItsRowAndColumnShape() {
        let rows: [[[Span]]] = [
            [[], [span("42")]],
            [[span("Name")], [span("Score")]],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let lines = out.string.split(separator: "\n", omittingEmptySubsequences: false)
        let firstRowCells = String(lines[0]).components(separatedBy: "\t")
        let secondRowCells = String(lines[1]).components(separatedBy: "\t")
        XCTAssertEqual(firstRowCells.count, 2, "the empty first cell must still leave its column tab")
        XCTAssertEqual(firstRowCells[0], "")
        XCTAssertEqual(firstRowCells[1], "42")
        XCTAssertEqual(secondRowCells, ["Name", "Score"])
    }

    func testTableHeaderRowIsShadedWithThemeHeaderBackground() {
        let out = build([.table(rows: [[[span("H1")], [span("H2")]], [[span("v1")], [span("v2")]]], headerRows: 1)])
        let headerBg = out.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(headerBg, Palette.tableHeaderBg)
        let bodyRowStart = (out.string as NSString).range(of: "v1").location
        let bodyBg = out.attribute(.backgroundColor, at: bodyRowStart, effectiveRange: nil) as? NSColor
        XCTAssertNil(bodyBg, "only the header row is shaded")
    }

    /// `headerRows: 0` — the "source can't tell us" case — must render row 0 as ordinary content:
    /// no bold, no header shading. Defaulting this to look like a header would misrepresent a
    /// document that never had one (see `OfficeBlock.table`).
    func testHeaderRowsZeroRendersFirstRowWithPlainBodyAttributes() {
        let out = build([.table(rows: [[[span("H1")], [span("H2")]], [[span("v1")], [span("v2")]]], headerRows: 0)])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold), "headerRows: 0 must not bold row 0")
        let bg = out.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNil(bg, "headerRows: 0 must not shade row 0")
    }

    // MARK: Images

    /// Requirement 7 / invariant 1: the reserved size must be exactly the declared size, and the
    /// image itself must be nil — pixels arrive in a later sprint, and loading them must never
    /// change layout (only redraw).
    func testImageBlockReservesExactSizeWithNoPixelsYet() throws {
        let size = CGSize(width: 240, height: 135)
        let out = build([.image(id: "rel42", size: size)])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        XCTAssertNil(attachment.image)
        XCTAssertEqual(attachment.attachmentCell?.cellSize(), size)
        let sizedCell = attachment.attachmentCell as? SizedAttachmentCell
        XCTAssertEqual(sizedCell?.reservedSize, size)
        let idValue = out.attribute(MDAttr.image, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(idValue, "rel42")
    }
}
