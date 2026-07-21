import Foundation

/// `.docx` bytes → `[OfficeBlock]`. Word's own container is three XML parts inside the ZIP
/// `ZipArchive` already knows how to open: `word/document.xml` (the body, required), and two
/// optional ones this reader consults to resolve what the body only references by id —
/// `word/styles.xml` (a paragraph style's `w:outlineLvl`, which is what actually makes it a
/// heading) and `word/numbering.xml` (whether a list level is a bullet or a number). Neither
/// being absent is an error — Word omits `numbering.xml` from documents with no lists at all —
/// so both fall back to an empty table and the body still parses.
enum DocxReader {
    enum ReadError: Swift.Error, Equatable, LocalizedError {
        /// `word/document.xml` is missing from the archive. Returning an empty document here
        /// would look like a genuinely blank file — the worst failure mode for a reader — so
        /// this throws instead.
        case missingDocumentXML
        /// A required XML part did not parse (malformed XML). Named by its archive path so the
        /// error is actionable.
        case malformedXML(String)

        var errorDescription: String? {
            switch self {
            case .missingDocumentXML:
                return "This .docx file has no word/document.xml — it may be corrupt."
            case .malformedXML(let part):
                return "\"\(part)\" could not be parsed as XML."
            }
        }
    }

    /// Images are OUT OF SCOPE this sprint (a later sprint resolves `w:drawing` relationship ids
    /// to pixels) — `w:drawing` is simply never matched below, so it is silently ignored inside
    /// whatever run contains it.
    static func read(_ archive: ZipArchive) throws -> [OfficeBlock] {
        guard archive.contains("word/document.xml") else { throw ReadError.missingDocumentXML }
        guard let documentRoot = try? buildTree(archive.data(for: "word/document.xml")) else {
            throw ReadError.malformedXML("word/document.xml")
        }
        let styleOutlineLevels = parseStyles(from: archive)
        let numbering = parseNumbering(from: archive)
        guard let body = documentRoot.child("w:body") else { return [] }
        return parseBody(body, styleOutlineLevels: styleOutlineLevels, numbering: numbering)
    }

    // MARK: styles.xml — styleId → outlineLvl

    /// A style's NAME is not a safe signal — a localized Word install renames "Heading1" to
    /// something like 제목 1, but `w:outlineLvl` is written in every language. Only paragraph
    /// styles that declare one are recorded; everything else (including styles with no
    /// `w:outlineLvl` at all) is absent from the map, which `headingLevel` reads as "not a
    /// heading style".
    private static func parseStyles(from archive: ZipArchive) -> [String: Int] {
        guard archive.contains("word/styles.xml"),
              let data = try? archive.data(for: "word/styles.xml"),
              let root = try? buildTree(data)
        else { return [:] }
        var map: [String: Int] = [:]
        for style in root.children where style.name == "w:style" {
            guard let id = style.attributes["w:styleId"],
                  let val = style.child("w:pPr")?.child("w:outlineLvl")?.attributes["w:val"],
                  let level = Int(val)
            else { continue }
            map[id] = level
        }
        return map
    }

    /// `outlineLvl` 0–8 are real heading levels; 9 is what Word gives its own `TOCHeading` style
    /// and must NOT be treated as a heading (it would otherwise put a table-of-contents label at
    /// sidebar depth 10). The emitted level is clamped to 1–6 — the vocabulary `OfficeBlock`
    /// offers — so an `outlineLvl` of 6, 7 or 8 all render as level 6 rather than being refused.
    private static func headingLevel(pStyleId: String?, styleOutlineLevels: [String: Int]) -> Int? {
        guard let id = pStyleId, let level = styleOutlineLevels[id], level <= 8 else { return nil }
        return min(level + 1, 6)
    }

    // MARK: numbering.xml — numId → abstractNumId → level → numFmt

    private struct NumberingInfo {
        var abstractNumIdByNumId: [String: String] = [:]
        var levelFormatsByAbstractNumId: [String: [Int: String]] = [:]
    }

    /// Read only as far as telling a bullet from a number apart — the mapping a real list needs
    /// to be classified, not to be rendered (`OfficeTextBuilder` derives the actual "1. 2. 3."
    /// numbers from `level` + `ordered` alone; this reader never counts list items).
    private static func parseNumbering(from archive: ZipArchive) -> NumberingInfo {
        guard archive.contains("word/numbering.xml"),
              let data = try? archive.data(for: "word/numbering.xml"),
              let root = try? buildTree(data)
        else { return NumberingInfo() }
        var info = NumberingInfo()
        for child in root.children {
            switch child.name {
            case "w:abstractNum":
                guard let abstractId = child.attributes["w:abstractNumId"] else { continue }
                var levels: [Int: String] = [:]
                for lvl in child.children where lvl.name == "w:lvl" {
                    guard let ilvlString = lvl.attributes["w:ilvl"], let ilvl = Int(ilvlString),
                          let fmt = lvl.child("w:numFmt")?.attributes["w:val"]
                    else { continue }
                    levels[ilvl] = fmt
                }
                info.levelFormatsByAbstractNumId[abstractId] = levels
            case "w:num":
                guard let numId = child.attributes["w:numId"],
                      let abstractRef = child.child("w:abstractNumId")?.attributes["w:val"]
                else { continue }
                info.abstractNumIdByNumId[numId] = abstractRef
            default:
                continue
            }
        }
        return info
    }

    /// Unresolvable input — no `numbering.xml` in the archive, or a `numId`/level it doesn't
    /// mention — defaults to unordered (a bullet), never ordered: an unnumbered document is a
    /// faithful reading, a fabricated "1. 2. 3." on plain bullets is not.
    private static func isOrdered(numId: String?, ilvl: Int, info: NumberingInfo) -> Bool {
        guard let numId,
              let abstractId = info.abstractNumIdByNumId[numId],
              let fmt = info.levelFormatsByAbstractNumId[abstractId]?[ilvl]
        else { return false }
        return fmt != "bullet"
    }

    // MARK: word/document.xml — body → blocks

    private static func parseBody(
        _ body: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for child in body.children {
            switch child.name {
            case "w:p":
                blocks.append(parseParagraph(child, styleOutlineLevels: styleOutlineLevels, numbering: numbering))
            case "w:tbl":
                blocks.append(parseTable(child))
            default:
                // e.g. the body's own trailing `w:sectPr` (page setup) — not a block.
                continue
            }
        }
        return blocks
    }

    private static func parseParagraph(
        _ p: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo
    ) -> OfficeBlock {
        let pPr = p.child("w:pPr")
        let spans = collectSpans(in: p)
        // Heading wins over list, even when the paragraph ALSO carries `w:numPr` — Word-authored
        // contracts routinely attach a multilevel list to their heading styles so "1. Definitions"
        // / "2.1 Interpretation" number themselves, and `outlineLvl` is the author's explicit
        // "this is a heading at level N"; `numPr` only says how it happens to be numbered. Word's
        // own navigation pane treats such a paragraph as a heading, not a list item, and the
        // heading level already carries the hierarchy a list level would have expressed. Losing
        // this precedence would drop every clause heading in such a document out of the outline
        // sidebar — silently, since parsing still "succeeds". `outlineLvl 9` is still not a
        // heading (see `headingLevel`), so that case correctly falls through to `.listItem` below.
        let pStyleId = pPr?.child("w:pStyle")?.attributes["w:val"]
        if let level = headingLevel(pStyleId: pStyleId, styleOutlineLevels: styleOutlineLevels) {
            return .heading(level: level, spans: spans)
        }
        if let numPr = pPr?.child("w:numPr") {
            let ilvl = Int(numPr.child("w:ilvl")?.attributes["w:val"] ?? "") ?? 0
            let numId = numPr.child("w:numId")?.attributes["w:val"]
            return .listItem(level: ilvl, ordered: isOrdered(numId: numId, ilvl: ilvl, info: numbering), spans: spans)
        }
        return .paragraph(spans: spans)
    }

    private static func parseTable(_ tbl: XMLNode) -> OfficeBlock {
        let rowNodes = tbl.children.filter { $0.name == "w:tr" }
        let rows: [[[Span]]] = rowNodes.map { row in
            row.children.filter { $0.name == "w:tc" }.map { cell in
                cell.children.filter { $0.name == "w:p" }.flatMap { collectSpans(in: $0) }
            }
        }
        // Leading run only — a header row can never follow an ordinary one, and the source is
        // trusted over any guess (an un-marked table defaults to `headerRows: 0`, never 1).
        var headerRows = 0
        for row in rowNodes {
            let isHeader = row.child("w:trPr")?.children.contains { $0.name == "w:tblHeader" } ?? false
            guard isHeader else { break }
            headerRows += 1
        }
        return .table(rows: rows, headerRows: headerRows)
    }

    /// Walks a paragraph (or a table cell's paragraph) collecting `w:r` runs into `Span`s,
    /// merging consecutive runs that carry identical formatting into one — Word fragments a
    /// single sentence into several runs constantly (a spell-check pass, a single character
    /// pasted with different provenance), and without merging, that fragmentation would leak
    /// into the rendered text as spurious style boundaries.
    ///
    /// Recursion is deliberately permissive: any wrapper this switch doesn't specifically name
    /// (`w:ins`, `w:hyperlink`, `w:smartTag`, `w:customXml`, …) is descended into rather than
    /// skipped, so a run's visible text is never lost just because Word wrapped it in something
    /// unanticipated. Only elements known to carry NO renderable body text of their own are
    /// pruned: paragraph/run properties (formatting only), deleted-content wrappers, empty
    /// markers, and section properties.
    private static func collectSpans(in node: XMLNode) -> [Span] {
        var spans: [Span] = []
        func appendMerging(_ span: Span) {
            if let last = spans.last, last.bold == span.bold, last.italic == span.italic,
               last.underline == span.underline, last.code == span.code {
                spans[spans.count - 1].text += span.text
            } else {
                spans.append(span)
            }
        }
        func walk(_ node: XMLNode) {
            for child in node.children {
                switch child.name {
                case "w:pPr", "w:rPr", "w:del", "w:bookmarkStart", "w:bookmarkEnd", "w:proofErr",
                     "w:sectPr", "w:commentRangeStart", "w:commentRangeEnd", "w:commentReference":
                    continue
                case "w:r":
                    if let span = buildSpan(from: child) { appendMerging(span) }
                default:
                    walk(child)
                }
            }
        }
        walk(node)
        return spans
    }

    /// `w:t` text is concatenated verbatim, including any leading/trailing spaces — `xml:space`
    /// is a hint to XML WRITERS about whether to preserve whitespace-only nodes; a parser already
    /// reports the literal characters present, so there is nothing extra to honour here (and
    /// nothing here trims). `w:br`/`w:tab` are not text but stand for one, so they are turned
    /// into `\n`/`\t` in place. A run producing no text at all (formatting-only, or an empty
    /// bookmark anchor Word occasionally wraps in its own run) yields no span — the caller must
    /// never see a phantom empty one.
    private static func buildSpan(from run: XMLNode) -> Span? {
        var text = ""
        for child in run.children {
            switch child.name {
            case "w:t": text += child.text
            case "w:br": text += "\n"
            case "w:tab": text += "\t"
            default: continue
            }
        }
        guard !text.isEmpty else { return nil }
        let rPr = run.child("w:rPr")
        return Span(text: text, bold: isOn(rPr, "w:b"), italic: isOn(rPr, "w:i"), underline: isOn(rPr, "w:u"))
    }

    /// A run-property toggle (`w:b`/`w:i`/`w:u`) is ON by its mere presence — UNLESS it carries
    /// `w:val="0"` or `w:val="false"`, which is Word's way of explicitly switching an inherited
    /// toggle back off. Treating `<w:b w:val="0"/>` as bold is a real, documented bug class.
    private static func isOn(_ rPr: XMLNode?, _ tag: String) -> Bool {
        guard let element = rPr?.child(tag) else { return false }
        guard let val = element.attributes["w:val"] else { return true }
        return val != "0" && val != "false"
    }

    // MARK: Generic XML tree

    private static func buildTree(_ data: Data) throws -> XMLNode {
        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw ReadError.malformedXML("xml")
        }
        return root
    }
}

/// A minimal DOM: element name (the qualified name, e.g. `"w:p"` — namespace processing is left
/// off, so `XMLParser` hands that back directly instead of splitting prefix from URI), its
/// attributes, its element children in document order, and any character data that landed
/// directly inside it (only leaf elements like `w:t` ever have any).
///
/// A tree — not a flat event stream — because `DocxReader`'s job is inherently structural
/// (a table's rows nest cells which nest paragraphs which nest runs); re-deriving that nesting
/// from `XMLParser`'s start/end callbacks by hand for every element kind would be the same tree,
/// built once per caller instead of once here.
private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// First direct child with this name, or nil. Every lookup `DocxReader` needs (`w:pPr` on a
    /// paragraph, `w:outlineLvl` on `w:pPr`, …) is for a single expected child, never a list.
    func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        stack.removeLast()
    }
}
