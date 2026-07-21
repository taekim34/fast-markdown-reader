import AppKit

/// `.rtf` bytes → `[OfficeBlock]`. RTF is the odd one out among the office formats this codebase
/// reads: it is not a ZIP archive, and AppKit already carries a complete RTF parser —
/// `NSAttributedString(data:options:documentAttributes:)`, the same importer TextEdit itself uses
/// to open a `.rtf` file. This reader's only job is translating THAT result into this codebase's
/// block vocabulary; it never parses an RTF control word by hand.
enum RtfReader {
    enum ReadError: Swift.Error, Equatable, LocalizedError {
        /// AppKit's own RTF importer rejected the bytes (empty data, not RTF at all, or RTF too
        /// malformed to open) — returning an empty document here would look like a genuinely blank
        /// file, so this throws instead, exactly like `DocxReader.ReadError.missingDocumentXML`.
        case invalidRTF

        var errorDescription: String? {
            switch self {
            case .invalidRTF:
                return "This file could not be read as RTF — it may be corrupt."
            }
        }
    }

    /// Unlike `.docx`/`.odt`, RTF has no archive a later sprint can pull an image's bytes from —
    /// an attachment's bytes are only ever available WHILE walking AppKit's parsed result, so the
    /// id/bytes pair must travel together from the start (`media`), not be resolved lazily.
    static func read(_ data: Data) throws -> (blocks: [OfficeBlock], media: [String: Data]) {
        var documentAttributes: NSDictionary?
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: &documentAttributes)
        } catch {
            throw ReadError.invalidRTF
        }
        return convert(attributed)
    }

    /// Split out from `read` so the image-attachment path can be exercised directly against an
    /// `NSAttributedString` built BY A TEST, bypassing AppKit's own RTF import — measured, not
    /// assumed: AppKit's RTF importer does not surface an embedded `\pict` picture as an
    /// `NSTextAttachment` at all on this platform (verified three ways — `pngblip`, `jpegblip` and
    /// a raw `dibitmap` all silently vanish from the parsed string with zero-length output, and
    /// TextEdit itself — the reference consumer of this exact importer — fails to render the
    /// picture from a real, LibreOffice-produced RTF confirmed BY BYTE INSPECTION to contain a
    /// well-formed `\pict\pngblip`). So there is no real `.rtf` file this reader can be handed that
    /// will ever reach this function with an attachment in it; this seam exists so the
    /// image-handling code below is still honestly unit-tested rather than untested dead logic,
    /// and so it is READY the day AppKit's importer does surface one (RTFD, or a future OS, does).
    static func convert(_ attributed: NSAttributedString) -> (blocks: [OfficeBlock], media: [String: Data]) {
        var blocks: [OfficeBlock] = []
        var media: [String: Data] = [:]
        var mediaIndex = 0
        let full = attributed.string as NSString
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byParagraphs) { _, range, _, _ in
            let (spans, images) = collectRuns(attributed, in: range, mediaIndex: &mediaIndex, media: &media)
            // A paragraph carrying ONLY a picture (spans empty, the common case: an image sits in
            // a paragraph of its own) contributes no phantom `.paragraph(spans: [])` — same
            // convention `DocxReader.parseParagraph` uses. An ordinary blank line (spans empty,
            // no image) DOES still get its block: unlike a docx paragraph, RTF has no other reader
            // to fall back on for "this blank line is spacing the author typed", so it is kept,
            // matching `PlainTextRenderer`'s treatment of a blank source line as real content.
            let skipEmptyText = spans.isEmpty && !images.isEmpty
            if !skipEmptyText {
                blocks.append(.paragraph(spans: spans))
            }
            blocks.append(contentsOf: images)
        }
        return (blocks, media)
    }

    // MARK: One paragraph's runs → spans + image blocks

    /// Walks every attribute run inside `range` (one paragraph). A run carrying `.attachment` is
    /// an embedded picture and contributes an `OfficeBlock.image`, never text; every other run
    /// contributes a `Span`, with consecutive runs of identical formatting merged into one — same
    /// reasoning as `DocxReader.collectSpans`: RTF fragments a sentence into several runs just as
    /// readily as Word does (a spell-check pass, text pasted from two sources), and without
    /// merging that fragmentation would leak into the render as spurious style boundaries.
    private static func collectRuns(
        _ attributed: NSAttributedString, in range: NSRange, mediaIndex: inout Int, media: inout [String: Data]
    ) -> (spans: [Span], images: [OfficeBlock]) {
        var spans: [Span] = []
        var images: [OfficeBlock] = []
        let full = attributed.string as NSString
        func appendMerging(_ span: Span) {
            if let last = spans.last, last.bold == span.bold, last.italic == span.italic,
               last.underline == span.underline, last.code == span.code {
                spans[spans.count - 1].text += span.text
            } else {
                spans.append(span)
            }
        }
        attributed.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                images.append(imageBlock(for: attachment, mediaIndex: &mediaIndex, media: &media))
                return
            }
            let text = full.substring(with: subrange)
            guard !text.isEmpty else { return }
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
            appendMerging(Span(text: text, bold: traits.contains(.bold), italic: traits.contains(.italic), underline: underline))
        }
        return (spans, images)
    }

    // MARK: Images

    /// A best-defensible non-zero fallback (invariant 1: never reserve a zero/collapsed layout
    /// area) for an attachment this reader can size no other way — same value, same reasoning, as
    /// `DocxReader.unresolvedVMLSize`.
    private static let unresolvedImageSize = CGSize(width: 72, height: 72)

    /// An attachment's id is minted here (`"rtf-media/<n>.<ext>"`) rather than read off anything
    /// in the source, because RTF's own attachment identity — `\*\picprop`'s `wzName` — is
    /// optional and frequently blank; a stable, always-present counter is the only identity this
    /// reader can promise. An attachment with no readable bytes at all still emits a sized block,
    /// with an id in the `"rtf-unresolvable:…"` form — the office-wide analogue of
    /// `DocxReader.unresolvableId`, which is docx-specific (`"docx-unresolvable:…"`) — so a
    /// picture never silently vanishes from the block list just because its data didn't load.
    private static func imageBlock(for attachment: NSTextAttachment, mediaIndex: inout Int, media: inout [String: Data]) -> OfficeBlock {
        guard let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.image?.tiffRepresentation, !bytes.isEmpty else {
            return .image(id: "rtf-unresolvable:no-image-data", size: unresolvedImageSize)
        }
        let id = "rtf-media/\(mediaIndex).\(fileExtension(for: bytes, wrapper: attachment.fileWrapper))"
        mediaIndex += 1
        media[id] = bytes
        return .image(id: id, size: resolvedSize(of: attachment, bytes: bytes))
    }

    /// The attachment's own DECLARED size (`bounds`) is authoritative when present — an attacher
    /// can legitimately draw a picture larger or smaller than its native pixels, exactly like a
    /// docx `wp:extent`. Only when nothing declares a size at all does this fall back to the
    /// image's own pixel size at 72 dpi (1 pixel = 1 point, this codebase's convention — see
    /// `DocxReader.emuToPoints`, 72 pt/inch), and only when even THAT can't be read does it fall
    /// back to `unresolvedImageSize`.
    private static func resolvedSize(of attachment: NSTextAttachment, bytes: Data) -> CGSize {
        let declared = attachment.bounds.size
        if declared.width > 0, declared.height > 0 { return declared }
        if let imageSize = attachment.image?.size, imageSize.width > 0, imageSize.height > 0 { return imageSize }
        if let rep = NSBitmapImageRep(data: bytes), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return unresolvedImageSize
    }

    /// The wrapper's own filename is trusted first (an attachment built from a real file, as a
    /// test does, already knows its extension); failing that, the bytes' own magic number picks
    /// among the formats RTF pictures actually arrive as. `"bin"` is a deliberately inert fallback
    /// for anything else — never guessed as `"png"`, which would tell a later sprint to hand these
    /// bytes to an image decoder that will just fail again.
    private static func fileExtension(for bytes: Data, wrapper: FileWrapper?) -> String {
        if let name = wrapper?.preferredFilename, let dotIndex = name.lastIndex(of: ".") {
            return String(name[name.index(after: dotIndex)...]).lowercased()
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.starts(with: [0x49, 0x49]) || bytes.starts(with: [0x4D, 0x4D]) { return "tiff" }
        return "bin"
    }
}
