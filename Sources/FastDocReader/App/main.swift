import AppKit

// Headless text extraction: `FastDocReader --extract <file>` prints Markdown and exits BEFORE any
// GUI setup — no NSApplication, no window, no Dock icon. This must run first so an AI agent can pipe
// a .docx/.odt straight to Markdown without paying to parse the zip/XML itself (see HeadlessExtract).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--extract" {
    exit(HeadlessExtract.run(Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
