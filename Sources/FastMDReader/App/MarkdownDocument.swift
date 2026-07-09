import AppKit

final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

    override class var autosavesInPlace: Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        self.text = String(decoding: data, as: UTF8.self)
    }

    override func makeWindowControllers() {
        let wc = DocumentWindowController()
        addWindowController(wc)
        wc.window?.setFrameAutosaveName("FastMDReaderDoc")
        render(into: wc)
    }

    private func render(into wc: DocumentWindowController) {
        // FontSizeStore is the SINGLE owner of font size — never read UserDefaults directly.
        let attr = MarkdownRenderer.render(text, theme: .current(size: FontSizeStore.size))
        wc.display(attr)
        wc.window?.title = displayName ?? "fast-md-reader"
    }
}
