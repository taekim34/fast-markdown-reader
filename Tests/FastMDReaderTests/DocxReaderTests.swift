import XCTest
@testable import FastMDReader

/// `DocxReader` is pure: build a `.docx`-shaped ZIP by hand (stored entries only — no need to
/// deflate to exercise the reader), hand it to `ZipArchive`, then `DocxReader.read`, and assert
/// on the `[OfficeBlock]` that comes back. Same shape as `ZipArchiveTests` — no fixture files on
/// disk, no view, no document.
final class DocxReaderTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Builds a minimal `.docx`-shaped archive: `word/document.xml` always, `word/styles.xml`
    /// and `word/numbering.xml` only when provided (Word itself omits `numbering.xml` from
    /// documents with no lists — several tests below exercise that).
    private func buildDocx(document: String, styles: String? = nil, numbering: String? = nil) -> Data {
        var entries: [(String, Data)] = [("word/document.xml", Data(document.utf8))]
        if let styles { entries.append(("word/styles.xml", Data(styles.utf8))) }
        if let numbering { entries.append(("word/numbering.xml", Data(numbering.utf8))) }
        return buildZip(entries)
    }

    private func buildZip(_ entries: [(name: String, content: Data)]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50)                  // local file header signature
            body += le16(20)                            // version needed to extract
            body += le16(0)                              // general purpose bit flag
            body += le16(0)                              // compression method: stored
            body += le16(0) + le16(0)                    // mod time, mod date
            body += le32(0)                               // crc-32 (unused by ZipArchive)
            body += le32(UInt32(content.count))           // compressed size == uncompressed for stored
            body += le32(UInt32(content.count))           // uncompressed size
            body += le16(UInt16(nameBytes.count))
            body += le16(0)                                // extra field length
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var centralDirectory = [UInt8]()
        for p in prepared {
            centralDirectory += le32(0x0201_4b50)          // central directory signature
            centralDirectory += le16(20) + le16(20)         // version made by, version needed
            centralDirectory += le16(0)                       // general purpose bit flag
            centralDirectory += le16(0)                       // compression method: stored
            centralDirectory += le16(0) + le16(0)              // mod time, mod date
            centralDirectory += le32(0)                        // crc-32
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(0)                        // extra field length
            centralDirectory += le16(0)                        // file comment length
            centralDirectory += le16(0)                        // disk number start
            centralDirectory += le16(0)                        // internal attributes
            centralDirectory += le32(0)                        // external attributes
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
        }
        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)                       // end of central directory signature
        archive += le16(0) + le16(0)                         // disk number, disk with CD start
        archive += le16(UInt16(entries.count))                // records on this disk
        archive += le16(UInt16(entries.count))                // total records
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)                                     // comment length
        return Data(archive)
    }

    private func doc(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document><w:body>\(body)</w:body></w:document>"
    }

    private func read(document: String, styles: String? = nil, numbering: String? = nil) throws -> [OfficeBlock] {
        let zip = buildDocx(document: doc(document), styles: styles, numbering: numbering)
        let archive = try ZipArchive(data: zip)
        return try DocxReader.read(archive)
    }

    // MARK: Run reassembly

    func testFiveRunsWithIdenticalFormattingReassembleIntoOneSpan() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Hello</w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>, </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>world</w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>! </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Bye</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Hello, world! Bye", bold: true)])])
    }

    func testRunsWithDifferentFormattingStaySeparateInOrder() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Bold</w:t></w:r>
          <w:r><w:t>Plain</w:t></w:r>
          <w:r><w:rPr><w:i/></w:rPr><w:t>Italic</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "Bold", bold: true),
            Span(text: "Plain"),
            Span(text: "Italic", italic: true),
        ])])
    }

    func testExplicitlyDisabledBoldIsNotBold() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>NotBold</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "NotBold", bold: false)])])
    }

    // MARK: Headings via outlineLvl

    private let headingStyles = """
    <w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading2"><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading3"><w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading4"><w:pPr><w:outlineLvl w:val="3"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading5"><w:pPr><w:outlineLvl w:val="4"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading6"><w:pPr><w:outlineLvl w:val="5"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading7"><w:pPr><w:outlineLvl w:val="6"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading8"><w:pPr><w:outlineLvl w:val="7"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading9"><w:pPr><w:outlineLvl w:val="8"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="TOCHeading"><w:pPr><w:outlineLvl w:val="9"/></w:pPr></w:style>
    </w:styles>
    """

    func testOutlineLevelsZeroThroughFiveMapToHeadingLevelsOneThroughSix() throws {
        let paragraphs = (1...6).map { "<w:p><w:pPr><w:pStyle w:val=\"Heading\($0)\"/></w:pPr><w:r><w:t>H\($0)</w:t></w:r></w:p>" }
        let blocks = try read(document: paragraphs.joined(), styles: headingStyles)
        XCTAssertEqual(blocks, (1...6).map { .heading(level: $0, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelsSixSevenEightClampToHeadingLevelSix() throws {
        let paragraphs = (7...9).map { "<w:p><w:pPr><w:pStyle w:val=\"Heading\($0)\"/></w:pPr><w:r><w:t>H\($0)</w:t></w:r></w:p>" }
        let blocks = try read(document: paragraphs.joined(), styles: headingStyles)
        XCTAssertEqual(blocks, (7...9).map { .heading(level: 6, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelNineIsNotAHeading() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"TOCHeading\"/></w:pPr><w:r><w:t>Contents</w:t></w:r></w:p>",
            styles: headingStyles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Contents")])])
    }

    func testUnknownParagraphStyleIsAnOrdinaryParagraph() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Compact\"/></w:pPr><w:r><w:t>Text</w:t></w:r></w:p>",
            styles: headingStyles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")])])
    }

    // MARK: Empty markers and revision wrappers

    func testBookmarksAndProofErrProduceNoPhantomSpansAndDoNotSplitARunPair() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>A</w:t></w:r>
          <w:bookmarkStart w:id="0" w:name="_GoBack"/>
          <w:bookmarkEnd w:id="0"/>
          <w:proofErr w:type="spellStart"/>
          <w:r><w:rPr><w:b/></w:rPr><w:t>B</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "AB", bold: true)])])
    }

    func testDeletedContentIsSkippedAndInsertedContentIsKept() throws {
        let blocks = try read(document: """
        <w:p>
          <w:del w:id="1" w:author="x"><w:r><w:delText>Deleted</w:delText></w:r></w:del>
          <w:ins w:id="2" w:author="x"><w:r><w:t>Inserted</w:t></w:r></w:ins>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Inserted")])])
    }

    // MARK: Breaks, tabs, whitespace

    func testLineBreakAndTabSurviveIntoText() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>Line1</w:t><w:br/><w:t>Line2</w:t><w:tab/><w:t>Col2</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Line1\nLine2\tCol2")])])
    }

    func testPreserveSpaceKeepsLeadingAndTrailingSpaces() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t xml:space="preserve">  spaced  </w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "  spaced  ")])])
    }

    // MARK: Lists

    private let bulletThenDecimalNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="1">
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="5"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """

    func testNestedListLevelsAndFormatsResolveViaNumbering() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Bullet</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Decimal</w:t></w:r></w:p>
        """, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: false, spans: [Span(text: "Bullet")]),
            .listItem(level: 1, ordered: true, spans: [Span(text: "Decimal")]),
        ])
    }

    func testHeadingStyleWithNumPrStillEmitsHeadingNotListItem() throws {
        let blocks = try read(
            document: """
            <w:p>
              <w:pPr>
                <w:pStyle w:val="Heading2"/>
                <w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr>
              </w:pPr>
              <w:r><w:t>Interpretation</w:t></w:r>
            </w:p>
            """,
            styles: headingStyles, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Interpretation")])])
    }

    func testNumPrWithoutHeadingStyleStillEmitsListItem() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>
        """, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    func testOutlineLevelNineWithNumPrStillEmitsListItem() throws {
        let blocks = try read(
            document: """
            <w:p>
              <w:pPr>
                <w:pStyle w:val="TOCHeading"/>
                <w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr>
              </w:pPr>
              <w:r><w:t>Contents</w:t></w:r>
            </w:p>
            """,
            styles: headingStyles, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 1, ordered: true, spans: [Span(text: "Contents")])])
    }

    func testMissingNumberingXMLDefaultsListsToUnordered() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    // MARK: Tables

    func testTwoByTwoTableWithAnEmptyCellKeepsShapeAndReportsHeaderRow() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr><w:trPr><w:tblHeader/></w:trPr>
            <w:tc><w:p><w:r><w:t>H1</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>H2</w:t></w:r></w:p></w:tc>
          </w:tr>
          <w:tr>
            <w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc>
            <w:tc><w:p></w:p></w:tc>
          </w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [[Span(text: "H1")], [Span(text: "H2")]],
            [[Span(text: "A1")], []],
        ], headerRows: 1)])
    }

    func testTableWithNoTblHeaderMarkerReportsZeroHeaderRows() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>D</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [[Span(text: "A")], [Span(text: "B")]],
            [[Span(text: "C")], [Span(text: "D")]],
        ], headerRows: 0)])
    }

    // MARK: Archive-level failure and absent optional parts

    func testArchiveWithNoDocumentXMLThrows() throws {
        let zip = buildZip([("word/styles.xml", Data(headingStyles.utf8))])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try DocxReader.read(archive)) { error in
            XCTAssertEqual(error as? DocxReader.ReadError, .missingDocumentXML)
        }
    }

    func testMissingStylesXMLStillParsesWithNoHeadingsAndNoCrash() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Plain text</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain text")])])
    }
}
