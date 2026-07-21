import Foundation
import CoreGraphics

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

    /// This reader emits `.image` blocks (see `collectImages`) — PARSING only. Resolving an
    /// emitted id to actual pixels (reading the archive entry, drawing a placeholder for an
    /// unresolvable one) is a later sprint's job.
    static func read(_ archive: ZipArchive) throws -> [OfficeBlock] {
        guard archive.contains("word/document.xml") else { throw ReadError.missingDocumentXML }
        guard let documentRoot = try? buildTree(archive.data(for: "word/document.xml")) else {
            throw ReadError.malformedXML("word/document.xml")
        }
        let styleOutlineLevels = parseStyles(from: archive)
        let numbering = parseNumbering(from: archive)
        let relationships = parseRelationships(from: archive)
        guard let body = documentRoot.child("w:body") else { return [] }
        return parseBody(body, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
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

    // MARK: word/_rels/document.xml.rels — relationship id → target

    private struct Relationship {
        /// Embedded: the archive entry path (`"word/media/image1.png"`) `ZipArchive.data(for:)`
        /// can read directly. External: the raw `Target` (a `file:///…` URL) — never a path into
        /// THIS archive, since the bytes live outside it.
        let target: String
        let external: Bool
    }

    private struct Relationships {
        var byId: [String: Relationship] = [:]
    }

    /// Absent from an image-less document exactly like `styles.xml`/`numbering.xml` — falls back
    /// to an empty table, so every `r:embed`/`r:link` lookup below simply misses and the reader
    /// still produces `.image` blocks (marked unresolvable) instead of crashing.
    private static func parseRelationships(from archive: ZipArchive) -> Relationships {
        guard archive.contains("word/_rels/document.xml.rels"),
              let data = try? archive.data(for: "word/_rels/document.xml.rels"),
              let root = try? buildTree(data)
        else { return Relationships() }
        var rels = Relationships()
        for rel in root.children where rel.name == "Relationship" {
            guard let id = rel.attributes["Id"], let target = rel.attributes["Target"] else { continue }
            let external = rel.attributes["TargetMode"] == "External"
            // An embedded Target is package-relative to `word/` ("media/image1.png"); an external
            // Target is already a complete `file:///…`/`http://…` reference and must not be
            // rewritten into a path that looks like it lives in this archive.
            rels.byId[id] = Relationship(target: external ? target : "word/" + target, external: external)
        }
        return rels
    }

    // MARK: Images — w:drawing (DrawingML) and w:pict (legacy VML)

    /// Descends into `mc:AlternateContent` via `mc:Choice` ONLY, never `mc:Fallback` — the two
    /// are alternative renderings of the SAME content (modern DrawingML vs. legacy VML, for a
    /// reader that doesn't understand the newer one), not two pieces of content. Walking both is
    /// the classic bug here: it turns every picture — or text box — in a document that carries
    /// this construct into two. A standalone `w:pict` (no `mc:AlternateContent` wrapper at all —
    /// common in documents saved by, or round-tripped through, an older Word) is genuine content
    /// and IS collected.
    ///
    /// A `w:drawing`/`w:pict` that resolves to no picture at all is NOT automatically an image —
    /// an AutoShape/text-box group is common (a callout box, a decorative rule) and reserving
    /// image space with a broken-picture placeholder for one would tell the reader a picture
    /// failed to load when there never was one. Such a shape contributes its TEXT instead, if it
    /// has any (`w:txbxContent`), and nothing at all if it has neither picture nor text.
    private static func collectDrawingBlocks(
        in node: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        func walk(_ node: XMLNode) {
            for child in node.children {
                switch child.name {
                case "mc:AlternateContent":
                    // `children.first` — if several `mc:Choice` were ever present, the first is
                    // Word's own preferred rendering.
                    if let choice = child.child("mc:Choice") { walk(choice) }
                case "w:drawing":
                    let pictures = imageBlocks(fromDrawing: child, relationships: relationships)
                    if !pictures.isEmpty {
                        blocks.append(contentsOf: pictures)
                    } else {
                        blocks.append(contentsOf: textBoxBlocks(
                            in: child, styleOutlineLevels: styleOutlineLevels, numbering: numbering,
                            relationships: relationships))
                    }
                case "w:pict":
                    if let block = imageBlock(fromPict: child, relationships: relationships) {
                        blocks.append(block)
                    } else {
                        blocks.append(contentsOf: textBoxBlocks(
                            in: child, styleOutlineLevels: styleOutlineLevels, numbering: numbering,
                            relationships: relationships))
                    }
                default:
                    walk(child)
                }
            }
        }
        walk(node)
        return blocks
    }

    /// A shape's caption/callout text lives in `w:txbxContent` (one or more, nested arbitrarily
    /// deep inside `wps:wsp`/`wpg:wgp`), each holding ordinary `w:p` paragraphs — reads them with
    /// the SAME paragraph classification as the document body (`parseParagraph`), so a heading or
    /// list style inside a text box is honoured exactly like one in the body. An empty paragraph
    /// here (Word leaves a placeholder `<w:p/>` in the text frame of an otherwise-empty AutoShape)
    /// is real content in the document BODY but not here — a shape with nothing typed into it has
    /// no text, and must produce no block; the body's own "empty paragraph = a blank line" reading
    /// does not apply to shape decoration.
    private static func textBoxBlocks(
        in node: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for txbx in node.allDescendants("w:txbxContent") {
            for p in txbx.children where p.name == "w:p" {
                let paragraphBlocks = parseParagraph(
                    p, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
                blocks.append(contentsOf: paragraphBlocks.filter { !isEmptyTextBlock($0) })
            }
        }
        return blocks
    }

    /// A text/heading/list block with no spans at all — used only to filter a text box's OWN
    /// placeholder-empty paragraph (see `textBoxBlocks`) out of what it contributes; an image or
    /// table block is never "empty" in this sense and always passes through.
    private static func isEmptyTextBlock(_ block: OfficeBlock) -> Bool {
        switch block {
        case .paragraph(let spans), .heading(_, let spans), .listItem(_, _, let spans):
            return spans.isEmpty
        case .table, .image:
            return false
        }
    }

    /// `wp:extent` (EMU) is present on both an inline (`wp:inline`) and a floating (`wp:anchor`)
    /// drawing, so it's read by name rather than by which wrapper it's under. No `wp:extent` means
    /// this isn't a shape this reader understands sizing for — silently produces no block, same as
    /// a run with no text at all producing no span. An empty result here also means "not a
    /// picture" to the caller, which then looks for text instead — so this must return `[]`, never
    /// an unresolvable placeholder, when there is no `a:blip` anywhere inside.
    ///
    /// A `w:drawing` isn't always ONE picture — Word groups multiple pictures under a single
    /// `w:drawing` (`wpg:wgp`) routinely (e.g. two logos placed side by side), and EVERY `a:blip`
    /// found inside is a real, separate picture that must not be silently merged into one or
    /// dropped (measured on the real government-guide test file: a single `w:drawing` there
    /// groups exactly two `pic:pic` elements, two DISTINCT embedded pictures). A picture inside a
    /// group is positioned and sized in that group's own LOCAL child coordinate space, not EMU —
    /// `groupScale`/`collectGroupedPictures` chain the real transform (every nested group's own
    /// `ext ÷ chExt`) down to each picture rather than approximating with the group's outer box.
    private static func imageBlocks(fromDrawing drawing: XMLNode, relationships: Relationships) -> [OfficeBlock] {
        guard let extent = drawing.firstDescendant("wp:extent"),
              let cx = extent.attributes["cx"].flatMap(Double.init),
              let cy = extent.attributes["cy"].flatMap(Double.init)
        else { return [] }
        let wholeDrawingSize = CGSize(width: emuToPoints(cx), height: emuToPoints(cy))
        guard let outerGroup = drawing.firstDescendant("wpg:wgp") else {
            // No group — by far the common case, a single inline/floating picture whose own box
            // IS the drawing's `wp:extent`. (Still collects every `a:blip`, not just the first,
            // in case Word ever emits more than one ungrouped — no real file exercises that, but
            // nothing here assumes exactly one.)
            return drawing.allDescendants("a:blip").map { blip in
                .image(id: resolveId(relId: blip.attributes["r:embed"] ?? blip.attributes["r:link"], relationships: relationships),
                       size: wholeDrawingSize)
            }
        }
        var images: [OfficeBlock] = []
        let scale = groupScale(of: outerGroup) ?? AxisScale(x: 1, y: 1)
        collectGroupedPictures(in: outerGroup, scale: scale, fallbackSize: wholeDrawingSize,
                                relationships: relationships, into: &images)
        return images
    }

    /// The multiplier that converts a value expressed in THIS group's own child-coordinate units
    /// (`wpg:grpSpPr/a:xfrm`'s `chOff`/`chExt`) into the units its OWN `off`/`ext` are expressed
    /// in (its parent's child units, or real EMU at the outermost group) — i.e. one link in the
    /// nested-group transform chain. `nil` when the group carries no usable `a:xfrm` (missing, or
    /// a degenerate `chExt` of 0 on an axis) — the caller then chains through unchanged on that
    /// axis rather than dividing by zero, which is a defensible "no additional scaling known"
    /// reading, not a crash.
    private struct AxisScale { var x: Double; var y: Double }

    private static func groupScale(of group: XMLNode) -> AxisScale? {
        guard let xfrm = group.child("wpg:grpSpPr")?.child("a:xfrm"),
              let ext = xfrm.child("a:ext"), let chExt = xfrm.child("a:chExt"),
              let extCx = ext.attributes["cx"].flatMap(Double.init), let extCy = ext.attributes["cy"].flatMap(Double.init),
              let chExtCx = chExt.attributes["cx"].flatMap(Double.init), let chExtCy = chExt.attributes["cy"].flatMap(Double.init)
        else { return nil }
        return AxisScale(x: chExtCx == 0 ? 1 : extCx / chExtCx, y: chExtCy == 0 ? 1 : extCy / chExtCy)
    }

    /// Walks one group's DIRECT children: a nested `wpg:grpSp` multiplies `scale` by its OWN
    /// `groupScale` and recurses (chaining the transform one more level down before it reaches
    /// any picture inside it); a `pic:pic` is sized by its own `pic:spPr/a:xfrm/a:ext` — read as a
    /// PRECISE direct-child path, never a broad descendant search, because `a:blip/a:extLst/a:ext`
    /// is an unrelated extension-marker element that also happens to be named `a:ext` and sits
    /// EARLIER in the same picture (an unqualified search would silently grab attributes with no
    /// `cx`/`cy` and look like "no size" instead of the real one) — converted with the accumulated
    /// `scale`. A picture that (unusually) carries no own `a:xfrm/a:ext` falls back to
    /// `fallbackSize` (the whole drawing's `wp:extent`) rather than a zero. Anything else at this
    /// level (`wps:wsp` — a connecting line, a plain AutoShape with no picture) contributes no
    /// image; its text, if any, is handled separately by `textBoxBlocks`.
    private static func collectGroupedPictures(
        in group: XMLNode, scale: AxisScale, fallbackSize: CGSize, relationships: Relationships, into images: inout [OfficeBlock]
    ) {
        for child in group.children {
            switch child.name {
            case "wpg:grpSp":
                let nestedScale: AxisScale
                if let inner = groupScale(of: child) {
                    nestedScale = AxisScale(x: scale.x * inner.x, y: scale.y * inner.y)
                } else {
                    nestedScale = scale
                }
                collectGroupedPictures(in: child, scale: nestedScale, fallbackSize: fallbackSize,
                                        relationships: relationships, into: &images)
            case "pic:pic":
                guard let blip = child.firstDescendant("a:blip") else { continue }
                let relId = blip.attributes["r:embed"] ?? blip.attributes["r:link"]
                let ownExt = child.child("pic:spPr")?.child("a:xfrm")?.child("a:ext")
                let size: CGSize
                if let ownExt, let cx = ownExt.attributes["cx"].flatMap(Double.init), let cy = ownExt.attributes["cy"].flatMap(Double.init) {
                    size = CGSize(width: emuToPoints(cx * scale.x), height: emuToPoints(cy * scale.y))
                } else {
                    size = fallbackSize
                }
                images.append(.image(id: resolveId(relId: relId, relationships: relationships), size: size))
            default:
                continue
            }
        }
    }

    /// A best-defensible non-zero fallback for a VML shape whose `style` is missing or doesn't
    /// parse — invariant 1 (never reserve a zero/collapsed area) applies just as much to a legacy
    /// shape this reader can't size as to a not-yet-loaded markdown image. One inch square is
    /// arbitrary but visible and stable; there is no better signal available in that case.
    private static let unresolvedVMLSize = CGSize(width: 72, height: 72)

    /// Legacy VML: the image reference is `v:imagedata/@r:id` (note `r:id`, not `r:embed` —
    /// VML predates the DrawingML relationship-attribute convention), and the size lives on the
    /// enclosing shape's CSS-like `style` attribute (`v:shape`/`v:rect`/…) rather than a
    /// dedicated extent element, so it's found by attribute rather than by element name. A single
    /// `w:pict` CAN itself group several `v:imagedata` (mirroring the DrawingML case above), but
    /// that only happens here as the Fallback half of an `mc:AlternateContent` this reader never
    /// descends into (see `collectImages`) — a genuinely standalone multi-picture VML group is not
    /// exercised by either real test file, so only the first `v:imagedata` is read; a document that
    /// hits this would still get one correctly-sized picture, not a crash or a dropped block.
    private static func imageBlock(fromPict pict: XMLNode, relationships: Relationships) -> OfficeBlock? {
        guard let imagedata = pict.firstDescendant("v:imagedata") else { return nil }
        let styleNode = pict.firstDescendant(withAttribute: "style")
        let size = parseVMLStyleSize(styleNode?.attributes["style"]) ?? unresolvedVMLSize
        return .image(id: resolveId(relId: imagedata.attributes["r:id"], relationships: relationships), size: size)
    }

    /// A relationship id resolves to the archive entry path for an embedded image, or to a
    /// clearly-marked, non-archive-shaped id (`"docx-unresolvable:…"`) for anything this reader
    /// cannot hand pixels for: no id on the element at all, an external (linked) target, or an id
    /// that doesn't appear in `document.xml.rels` at all (a malformed/edited document) — every one
    /// of these still returns a block, never nil, so a picture never silently vanishes from the
    /// block list. The later sprint that draws pixels is expected to treat this prefix as "always
    /// show a sized placeholder, never attempt an archive lookup".
    private static func resolveId(relId: String?, relationships: Relationships) -> String {
        guard let relId else { return unresolvableId("no-relationship-id") }
        guard let rel = relationships.byId[relId] else { return unresolvableId(relId) }
        return rel.external ? unresolvableId(rel.target) : rel.target
    }

    private static func unresolvableId(_ reason: String) -> String { "docx-unresolvable:\(reason)" }

    /// EMU (English Metric Units) is DrawingML's native length unit: 914400 per inch, 12700 per
    /// point (72 pt/inch × 12700 = 914400). Verified against the real test file: `cx="6400800"`
    /// (a 7-inch-wide picture) must yield exactly 504 pt.
    private static func emuToPoints(_ emu: Double) -> CGFloat { CGFloat(emu / 12700) }

    /// A `v:shape`-family `style` attribute is CSS-like declarations (`"width:7in;height:185.25pt"`),
    /// not real CSS — but `in`/`pt`/`px`/`cm`/`mm` behave like their CSS namesakes. A BARE number
    /// (no unit suffix, e.g. `width:1665`) is treated as points: that's Word's own convention for
    /// most unmarked VML dimensions, though a handful of older shapes instead use it as a drawing
    /// COORDINATE (relative to `coordsize`), which this does not attempt to detect — there is no
    /// reliable signal in the shape alone to tell the two apart, so the point-based reading is used
    /// as the best-defensible value rather than fabricating a zero.
    private static func parseVMLStyleSize(_ style: String?) -> CGSize? {
        guard let style else { return nil }
        var width: CGFloat?
        var height: CGFloat?
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parseCSSLikeLength(parts[1].trimmingCharacters(in: .whitespaces))
            if property == "width" { width = value }
            if property == "height" { height = value }
        }
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func parseCSSLikeLength(_ raw: String) -> CGFloat? {
        // Longest-suffix-first: "in" isn't a prefix collision here, but this keeps the table
        // self-evidently order-independent if a two-letter unit is ever added.
        let pointsPerUnit: [(suffix: String, factor: Double)] = [
            ("in", 72), ("pt", 1), ("px", 0.75), ("cm", 72 / 2.54), ("mm", 72 / 25.4),
        ]
        for (suffix, factor) in pointsPerUnit where raw.hasSuffix(suffix) {
            guard let number = Double(raw.dropLast(suffix.count)) else { return nil }
            return CGFloat(number * factor)
        }
        // No unit suffix — see the point-based fallback note on the caller.
        guard let number = Double(raw) else { return nil }
        return CGFloat(number)
    }

    // MARK: word/document.xml — body → blocks

    private static func parseBody(
        _ body: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for child in body.children {
            switch child.name {
            case "w:p":
                blocks.append(contentsOf: parseParagraph(
                    child, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships))
            case "w:tbl":
                blocks.append(parseTable(child))
            default:
                // e.g. the body's own trailing `w:sectPr` (page setup) — not a block.
                continue
            }
        }
        return blocks
    }

    /// A paragraph normally contributes exactly one block, but one carrying an image contributes
    /// its text block (if it has any text) FOLLOWED BY that image's block(s), in source order —
    /// never reordering the paragraph's own text to make room for the picture. A paragraph that
    /// carries ONLY a picture (spans empty, the common case: Word puts an image in a paragraph of
    /// its own) contributes no empty text block, so callers never see a phantom `.paragraph(spans: [])`
    /// standing in for a picture.
    private static func parseParagraph(
        _ p: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        let pPr = p.child("w:pPr")
        let spans = collectSpans(in: p)
        let drawingBlocks = collectDrawingBlocks(
            in: p, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
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
        let textBlock: OfficeBlock?
        let skipEmptyText = spans.isEmpty && !drawingBlocks.isEmpty
        if let level = headingLevel(pStyleId: pStyleId, styleOutlineLevels: styleOutlineLevels) {
            textBlock = skipEmptyText ? nil : .heading(level: level, spans: spans)
        } else if let numPr = pPr?.child("w:numPr") {
            let ilvl = Int(numPr.child("w:ilvl")?.attributes["w:val"] ?? "") ?? 0
            let numId = numPr.child("w:numId")?.attributes["w:val"]
            textBlock = skipEmptyText ? nil
                : .listItem(level: ilvl, ordered: isOrdered(numId: numId, ilvl: ilvl, info: numbering), spans: spans)
        } else {
            textBlock = skipEmptyText ? nil : .paragraph(spans: spans)
        }
        var blocks: [OfficeBlock] = []
        if let textBlock { blocks.append(textBlock) }
        blocks.append(contentsOf: drawingBlocks)
        return blocks
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

    /// First match anywhere below this node (depth-first, document order), for lookups where the
    /// exact nesting varies by producer — `wp:extent`/`a:blip` sit at a different depth inside an
    /// inline vs. a floating (`wp:anchor`) drawing, and pinning that depth would silently miss one
    /// of the two shapes.
    func firstDescendant(_ name: String) -> XMLNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    /// Same idea, keyed by attribute presence rather than element name — used to find the VML
    /// shape carrying a `style="width:…;height:…"` attribute without knowing whether it's a
    /// `v:shape`, `v:rect`, `v:roundrect`, ….
    func firstDescendant(withAttribute attribute: String) -> XMLNode? {
        for child in children {
            if child.attributes[attribute] != nil { return child }
            if let found = child.firstDescendant(withAttribute: attribute) { return found }
        }
        return nil
    }

    /// EVERY match anywhere below this node, in document order — unlike `firstDescendant`, used
    /// where stopping at the first would silently drop real content (a `w:drawing` grouping
    /// several pictures has one `a:blip` per picture, all of them real).
    func allDescendants(_ name: String) -> [XMLNode] {
        var result: [XMLNode] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.allDescendants(name))
        }
        return result
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
