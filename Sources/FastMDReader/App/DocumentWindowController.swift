import AppKit

final class DocumentWindowController: NSWindowController {
    // Explicit TextKit 1 stack (C2): building the view with init(frame:textContainer:)
    // guarantees the classic NSLayoutManager path instead of silently falling back
    // to TextKit 2 compatibility mode when layoutManager is later accessed.
    let textView: NSTextView
    private let scrollView = NSScrollView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred   // native tabs
        self.init(window: window)
        window.center()

        textView.isEditable = false
        textView.isSelectable = true          // mouse selection allowed
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        window.contentView = scrollView
    }

    override init(window: NSWindow?) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ attributed: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributed)
    }
}
