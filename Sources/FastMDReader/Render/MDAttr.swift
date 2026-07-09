import AppKit

/// Centralized custom NSAttributedString attribute keys (C5).
/// Producers (renderer) and consumers (window controller, reader view) must all
/// reference `MDAttr.*` — never raw string literals — so the producer→consumer
/// contract stays greppable and drift-free.
enum MDAttr {
    /// Value = the raw code string of a fenced code block (used by the copy-button overlay).
    static let codeBlock = NSAttributedString.Key("mdCodeBlock")
    /// Value = the code block's language string ("" if none) — lets the no-wrap overlay
    /// re-highlight with the same rules.
    static let codeLang = NSAttributedString.Key("mdCodeLang")
    /// Value = the mermaid diagram source (the document layer swaps it for a PDF attachment).
    static let mermaid = NSAttributedString.Key("mdMermaid")
    /// Value = the heading level (Int); scanned live to recompute heading jump offsets.
    static let heading = NSAttributedString.Key("mdHeading")
    /// Reserved for the reading-line highlight contract (kept for symmetry; the reading
    /// line itself is drawn via layout-manager temporary attributes, not stored).
    static let readingLine = NSAttributedString.Key("mdReadingLine")
}
