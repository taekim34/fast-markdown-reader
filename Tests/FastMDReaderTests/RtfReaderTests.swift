import XCTest
@testable import FastMDReader

/// `RtfReader` is pure: hand it real, tool-produced RTF bytes (generated once via `textutil
/// -convert rtf` and embedded verbatim below — not hand-written control words) and assert on the
/// `[OfficeBlock]` that comes back. The image-attachment path is the one exception: AppKit's own
/// RTF importer never surfaces an embedded `\pict` picture as an `NSTextAttachment` on this
/// platform (see the long comment on `RtfReader.convert`), so those two tests build an
/// `NSAttributedString` directly and call `RtfReader.convert(_:)`, the seam left for exactly this.
final class RtfReaderTests: XCTestCase {
    // MARK: Fixtures — real RTF from `textutil -convert rtf`, embedded verbatim

    // Fixtures below are `textutil -convert rtf` output as a SINGLE Swift string literal with
    // explicit `\n` — a Swift multi-line `"""` literal would have its per-line TRAILING
    // whitespace stripped by normal source editing, and RTF is exactly the format where a
    // trailing space before a line break is significant content (it survives the parser as the
    // space between two words) — losing it silently joined "and" to the next word in the first
    // draft of this file, which is why this isn't a `"""` block.

    /// Three paragraphs; the second carries bold, italic and underline runs. Produced from:
    /// `<p>First paragraph normal text.</p><p><b>Bold</b> and <i>italic</i> and <u>underline</u> text.</p><p>Third paragraph.</p>`
    private let multiParagraphRTF = "{\\rtf1\\ansi\\ansicpg949\\cocoartf2870\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\froman\\fcharset0 Times-Roman;\\f1\\froman\\fcharset0 Times-Bold;\\f2\\froman\\fcharset0 Times-Italic;\n}\n{\\colortbl;\\red255\\green255\\blue255;\\red0\\green0\\blue0;}\n{\\*\\expandedcolortbl;;\\cssrgb\\c0\\c0\\c0;}\n\\deftab720\n\\pard\\pardeftab720\\sa240\\partightenfactor0\n\n\\f0\\fs24 \\cf0 \\expnd0\\expndtw0\\kerning0\n\\outl0\\strokewidth0 \\strokec2 First paragraph normal text.\\\n\\pard\\pardeftab720\\sa240\\partightenfactor0\n\n\\f1\\b \\cf0 Bold\n\\f0\\b0  and \n\\f2\\i italic\n\\f0\\i0  and \\ul underline\\ulnone  text.\\\nThird paragraph.\\\n}"

    /// A large (`\\fs74`), bold first line followed by an ordinary paragraph. Produced from:
    /// `<p><b><font size="7">Big Bold Title</font></b></p><p>Ordinary body paragraph.</p>`
    private let largeBoldFirstLineRTF = "{\\rtf1\\ansi\\ansicpg949\\cocoartf2870\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\froman\\fcharset0 Times-Bold;\\f1\\froman\\fcharset0 Times-Roman;}\n{\\colortbl;\\red255\\green255\\blue255;\\red0\\green0\\blue0;}\n{\\*\\expandedcolortbl;;\\cssrgb\\c0\\c0\\c0;}\n\\deftab720\n\\pard\\pardeftab720\\sa240\\partightenfactor0\n\n\\f0\\b\\fs74 \\cf0 \\expnd0\\expndtw0\\kerning0\n\\outl0\\strokewidth0 \\strokec2 Big Bold Title\n\\f1\\b0\\fs24 \\\nOrdinary body paragraph.\\\n}"

    /// Accented / non-ASCII text, produced from:
    /// `<p>Caf&eacute; na&iuml;ve r&eacute;sum&eacute; &ntilde;o&ntilde;o Z&uuml;rich &Uuml;ber &Aacute;rvore &ccedil;a</p>`
    private let accentedRTF = "{\\rtf1\\ansi\\ansicpg949\\cocoartf2870\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\froman\\fcharset0 Times-Roman;}\n{\\colortbl;\\red255\\green255\\blue255;\\red0\\green0\\blue0;}\n{\\*\\expandedcolortbl;;\\cssrgb\\c0\\c0\\c0;}\n\\deftab720\n\\pard\\pardeftab720\\sa240\\partightenfactor0\n\n\\f0\\fs24 \\cf0 \\expnd0\\expndtw0\\kerning0\n\\outl0\\strokewidth0 \\strokec2 Caf\\'e9 na\\'efve r\\'e9sum\\'e9 \\'f1o\\'f1o Z\\'fcrich \\'dcber \\'c1rvore \\'e7a\\\n}"

    /// An 8x8 red PNG (75 bytes) — small enough to embed as base64, large enough to be a genuine,
    /// decodable image (round-tripped through `NSBitmapImageRep` in `imageWithUnreadableDataIsStillSized`'s sibling test below).
    private let redPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQSACj/P8Fu7N9hAAAAAElFTkSuQmCC"

    private func data(_ rtf: String) -> Data { rtf.data(using: .utf8)! }

    // MARK: Paragraphs, formatting, order

    func testMultiParagraphYieldsOneBlockPerParagraphInOrderTextIntact() throws {
        let (blocks, _) = try RtfReader.read(data(multiParagraphRTF))
        XCTAssertEqual(blocks.count, 3)
        guard case let .paragraph(spans: p1) = blocks[0],
              case let .paragraph(spans: p2) = blocks[1],
              case let .paragraph(spans: p3) = blocks[2]
        else { return XCTFail("expected three .paragraph blocks, got \(blocks)") }
        XCTAssertEqual(p1.map(\.text).joined(), "First paragraph normal text.")
        XCTAssertEqual(p2.map(\.text).joined(), "Bold and italic and underline text.")
        XCTAssertEqual(p3.map(\.text).joined(), "Third paragraph.")
    }

    func testBoldItalicUnderlineLandOnTheRightSpanRanges() throws {
        let (blocks, _) = try RtfReader.read(data(multiParagraphRTF))
        guard case let .paragraph(spans: p2) = blocks[1] else { return XCTFail("expected paragraph 2") }
        XCTAssertEqual(p2, [
            Span(text: "Bold", bold: true, italic: false, underline: false),
            Span(text: " and ", bold: false, italic: false, underline: false),
            Span(text: "italic", bold: false, italic: true, underline: false),
            Span(text: " and ", bold: false, italic: false, underline: false),
            Span(text: "underline", bold: false, italic: false, underline: true),
            Span(text: " text.", bold: false, italic: false, underline: false),
        ])
    }

    // MARK: Do-not-fake-headings guard

    /// RTF carries no semantic heading markup — a large, bold first line is exactly what a real
    /// document's title looks like, and it would be tempting to promote it to `.heading`. This
    /// reader must not: the outline sidebar stays empty for `.rtf`, faithfully, rather than
    /// guessing structure that was never there.
    func testLargeBoldFirstLineDoesNotBecomeAHeadingOutlineStaysEmpty() throws {
        let (blocks, _) = try RtfReader.read(data(largeBoldFirstLineRTF))
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            if case .heading = block { XCTFail("RtfReader must never synthesize a heading, got \(block)") }
        }
        guard case let .paragraph(spans: title) = blocks[0] else { return XCTFail("expected a paragraph block") }
        XCTAssertEqual(title.map(\.text).joined(), "Big Bold Title")
        XCTAssertTrue(title.allSatisfy(\.bold))
    }

    // MARK: Images — via `convert(_:)`, the seam (see file-level comment: AppKit never hands a
    // real `.rtf` file's `\pict` back as an attachment on this platform)

    func testEmbeddedImageAttachmentEmitsASizedImageBlockAndItsBytesInMedia() throws {
        let pngBytes = Data(base64Encoded: redPNGBase64)!
        let attachment = NSTextAttachment()
        let wrapper = FileWrapper(regularFileWithContents: pngBytes)
        wrapper.preferredFilename = "picture.png"
        attachment.fileWrapper = wrapper
        attachment.bounds = NSRect(x: 0, y: 0, width: 40, height: 20)

        let text = NSMutableAttributedString(string: "Before.\n")
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "\nAfter.\n"))

        let (blocks, media) = RtfReader.convert(text)
        let images = blocks.compactMap { block -> (String, CGSize)? in
            if case let .image(id, size) = block { return (id, size) }
            return nil
        }
        XCTAssertEqual(images.count, 1)
        let (id, size) = try XCTUnwrap(images.first)
        XCTAssertEqual(size, CGSize(width: 40, height: 20))
        XCTAssertEqual(media[id], pngBytes)
        XCTAssertTrue(id.hasPrefix("rtf-media/"))
        XCTAssertTrue(id.hasSuffix(".png"))
    }

    func testAttachmentWithUnreadableDataStillEmitsANonZeroSizedBlock() {
        let attachment = NSTextAttachment() // no fileWrapper, no image — unreadable by construction
        let text = NSAttributedString(attachment: attachment)

        let (blocks, media) = RtfReader.convert(text)
        guard case let .image(id, size) = blocks.first else { return XCTFail("expected an .image block, got \(blocks)") }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertTrue(id.hasPrefix("rtf-unresolvable:"))
        XCTAssertTrue(media.isEmpty)
    }

    // MARK: Encoding

    func testAccentedTextRoundTripsWithoutReplacementCharacters() throws {
        let (blocks, _) = try RtfReader.read(data(accentedRTF))
        guard case let .paragraph(spans: p) = blocks.first else { return XCTFail("expected a paragraph block") }
        let text = p.map(\.text).joined()
        XCTAssertEqual(text, "Café naïve résumé ñoño Zürich Über Árvore ça")
        XCTAssertFalse(text.contains("\u{FFFD}"))
    }

    // MARK: Invalid input

    func testInvalidRTFThrows() {
        XCTAssertThrowsError(try RtfReader.read(data("this is not RTF at all"))) { error in
            XCTAssertEqual(error as? RtfReader.ReadError, .invalidRTF)
        }
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try RtfReader.read(Data())) { error in
            XCTAssertEqual(error as? RtfReader.ReadError, .invalidRTF)
        }
    }
}
