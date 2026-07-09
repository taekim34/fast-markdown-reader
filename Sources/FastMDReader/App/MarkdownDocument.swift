import AppKit

final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

    override class var autosavesInPlace: Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperation) -> Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        self.text = String(decoding: data, as: UTF8.self)
    }

    override func makeWindowControllers() {
        let wc = DocumentWindowController()
        addWindowController(wc)
        wc.window?.setFrameAutosaveName("FastMDReaderDoc")
        render(into: wc)
    }

    // Replaced in M3 by the markdown renderer. For now, show raw text.
    private func render(into wc: DocumentWindowController) {
        let attr = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                         .foregroundColor: NSColor.textColor])
        wc.display(attr)
        wc.window?.title = displayName ?? "fast-md-reader"
    }
}
