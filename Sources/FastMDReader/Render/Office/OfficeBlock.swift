import AppKit

/// A single formatted run of text — the smallest unit `OfficeTextBuilder` styles. Traits are
/// independent flags, not mutually exclusive: a run can be bold AND italic AND underlined AND
/// `code` at once (an office format's run properties are independent axes, unlike markdown where
/// `` `code` `` can't nest inside `**bold**`) — `code` only changes which FONT/COLOR the run
/// renders with (see `OfficeTextBuilder`), it doesn't suppress the others.
struct Span: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var code: Bool = false
}

/// The format-neutral block vocabulary between a document-format parser (docx/odt/… — later
/// sprints) and `OfficeTextBuilder`, which turns these into typography. Deliberately knows
/// nothing about Word, ODF or XML: a parser's only job is to produce this vocabulary, and
/// `OfficeTextBuilder`'s only job is to consume it, so the two are built and tested apart.
enum OfficeBlock: Equatable {
    case heading(level: Int, spans: [Span])
    case paragraph(spans: [Span])
    /// `level` is a 0-based nesting depth. `ordered` selects "1. 2. 3." numbering — per level,
    /// restarting when a SHALLOWER level intervenes but continuing across a deeper nested run —
    /// vs a bullet. See `OfficeTextBuilder` for the exact restart rule.
    case listItem(level: Int, ordered: Bool, spans: [Span])
    /// Rows of cells of spans (`rows[row][col]`). `headerRows` is the count of LEADING rows that
    /// are a genuine header, and the SOURCE format must say so explicitly — docx marks it with
    /// `w:tblHeader`, a markdown table always has exactly one. It is not a guess `OfficeTextBuilder`
    /// makes: pass 0 when the format can't tell you. DEFAULT TO 0 WHEN UNKNOWN, never 1 — an
    /// un-styled table is a faithful rendering of the source; a wrongly-bolded row is a lie about
    /// it (real contracts commonly have zero header rows — guessing "row one" bolds ordinary text).
    case table(rows: [[[Span]]], headerRows: Int)
    /// `id` is an opaque key a later sprint resolves to pixels (a docx relationship id, an odt
    /// href, a markdown source path, …) — this sprint only reserves the LAYOUT area, exactly like
    /// a not-yet-loaded markdown image (invariant 1: reserved size must never depend on whether
    /// pixels are loaded).
    case image(id: String, size: CGSize)
}
