import XCTest
import AppKit
@testable import FastMDReader

/// S4: the wire-up from `.docx` bytes to an open, read-only window. `DocxReader`/`ZipArchive`/
/// `OfficeTextBuilder` are already proven pure elsewhere (`DocxReaderTests`, `ZipArchiveTests`) —
/// this file is about `MarkdownDocument`/`DocumentTypes` routing them correctly and the edit
/// surface staying shut, the same shape `SpliceRenderTests` uses to drive a document directly.
final class OfficeDocumentTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory (same shape as
    // `DocxReaderTests`, duplicated here so this file stays a self-contained unit).

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func buildZip(_ entries: [(name: String, content: Data)]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50)
            body += le16(20)
            body += le16(0)
            body += le16(0)
            body += le16(0) + le16(0)
            body += le32(0)
            body += le32(UInt32(content.count))
            body += le32(UInt32(content.count))
            body += le16(UInt16(nameBytes.count))
            body += le16(0)
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var centralDirectory = [UInt8]()
        for p in prepared {
            centralDirectory += le32(0x0201_4b50)
            centralDirectory += le16(20) + le16(20)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0) + le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
        }
        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)
        archive += le16(0) + le16(0)
        archive += le16(UInt16(entries.count))
        archive += le16(UInt16(entries.count))
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)
        return Data(archive)
    }

    private let headingStyles = """
    <?xml version="1.0" encoding="UTF-8"?><w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
    </w:styles>
    """

    /// One heading + one paragraph — enough to exercise the outline sidebar (`MDAttr.heading`) and
    /// the body text path in the same fixture.
    private func fixtureDocx() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>
          <w:p><w:r><w:t>Body text.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(headingStyles.utf8)),
        ])
    }

    /// Opens a fixture `.docx` through the real document/window pipeline, mirroring how
    /// `SpliceRenderTests.open` drives markdown/plain-text.
    private func openOffice(_ data: Data) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-fixture-\(UUID().uuidString).docx")
        try doc.read(from: data, ofType: "org.openxmlformats.wordprocessingml.document")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    private func headingLevels(_ storage: NSTextStorage) -> [Int] {
        var levels: [Int] = []
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let level = v as? Int { levels.append(level) }
        }
        return levels
    }

    // MARK: Extension → kind

    func testExtensionResolvesToKind() {
        XCTAssertEqual(DocumentTypes.kind(forExtension: "docx"), .office)
        XCTAssertEqual(DocumentTypes.kind(forExtension: "DOCX"), .office)   // case-insensitive, like the others
        XCTAssertEqual(DocumentTypes.kind(forExtension: "txt"), .plainText)
        XCTAssertEqual(DocumentTypes.kind(forExtension: "md"), .markdown)
    }

    func testOpensInAppIncludesDocx() {
        XCTAssertTrue(DocumentTypes.opensInApp("docx"))
    }

    // MARK: Reading a fixture

    func testReadingFixtureProducesNonEmptyTextWithMatchingHeadingLevels() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertFalse(storage.string.isEmpty)
        XCTAssertTrue(storage.string.contains("Title"))
        XCTAssertTrue(storage.string.contains("Body text."))
        XCTAssertEqual(headingLevels(storage), [1])
        // `text` stays empty — an office document has no editable source (invariant checked by
        // `data(ofType:)` below); the rendered string comes from `officeBlocks` alone.
        XCTAssertEqual(doc.text, "")
        XCTAssertEqual(doc.officeBlocks.count, 2)
    }

    func testMalformedArchiveThrowsRatherThanProducingAnEmptyDocument() {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-garbage.docx")
        XCTAssertThrowsError(try doc.read(from: Data([0x00, 0x01, 0x02, 0x03]),
                                          ofType: "org.openxmlformats.wordprocessingml.document"))
    }

    // MARK: Re-render, not a cached string

    func testRenderedResultChangesWithThemeFontSize() throws {
        let (doc, _) = try openOffice(fixtureDocx())
        // `render(into:)` calls `OfficeTextBuilder.build(officeBlocks, theme:)` fresh every time —
        // this is the storage the document keeps for that to be possible at all. Rebuilding it
        // directly at two theme sizes is the deterministic form of "a font-size change reflows the
        // document": if `officeBlocks` had been discarded in favor of a cached finished string,
        // there would be nothing here to rebuild from.
        let small = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: 14))
        let large = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: 28))
        let fontSmall = try XCTUnwrap(small.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let fontLarge = try XCTUnwrap(large.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(fontLarge.pointSize, fontSmall.pointSize,
                             "a font-size change must re-run OfficeTextBuilder.build, not redraw a cached string")
    }

    // MARK: Read-only enforcement

    func testDataOfTypeThrowsForOfficeDocument() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-save.docx")
        try doc.read(from: fixtureDocx(), ofType: "org.openxmlformats.wordprocessingml.document")
        XCTAssertThrowsError(try doc.data(ofType: "org.openxmlformats.wordprocessingml.document"))
    }

    /// The bug the S4 audit found: `addBlockBelow` used to treat "no `srcRange` at the anchor" —
    /// always true for an office document — as "the document is empty" and replaced the whole of
    /// `doc.text`, marking it dirty over content the reader never touched. This is the regression
    /// test for that fix, on the real object the bug lived in (`DocumentWindowController`), not a
    /// reimplementation of its logic.
    func testAddBlockBelowOnOfficeDocumentDoesNotTouchTextOrDirtyState() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        wc.addBlockBelow(atChar: 0)
        // The undo group closes on the NEXT run-loop turn (CLAUDE.md invariant 17) — but this path
        // must never even start an edit, so there is nothing to wait out; asserting immediately is
        // correct here, unlike a test that undoes an edit back to clean.
        XCTAssertEqual(doc.text, "")
        XCTAssertFalse(doc.isDocumentEdited)
    }

    // MARK: Regression — markdown and plain text unaffected

    func testMarkdownStillRendersThroughKind() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-md-\(UUID().uuidString).md")
        try doc.read(from: Data("# Hello\n\nWorld.\n".utf8), ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.kind, .markdown)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Hello"))
        XCTAssertEqual(headingLevels(storage), [1])
    }

    func testPlainTextStillRendersThroughKind() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-txt-\(UUID().uuidString).txt")
        try doc.read(from: Data("line one\nline two\n".utf8), ofType: "public.plain-text")
        XCTAssertEqual(doc.kind, .plainText)
        XCTAssertTrue(doc.isPlainText)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(storage.string, "line one\nline two\n")
    }
}
