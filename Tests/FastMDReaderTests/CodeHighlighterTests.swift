import XCTest
import AppKit
@testable import FastMDReader

final class CodeHighlighterTests: XCTestCase {
    private let theme = RenderTheme.current(size: 14)

    func testUnknownLanguageIsPlainMonospace() {
        let s = CodeHighlighter.highlight("foo bar", language: "brainfuck", theme: theme)
        XCTAssertEqual(s.string, "foo bar")
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testSwiftKeywordIsColored() {
        let s = CodeHighlighter.highlight("let x = 1", language: "swift", theme: theme)
        let kwColor = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let numRange = s.string.range(of: "1")!
        let numOffset = s.string.distance(from: s.string.startIndex, to: numRange.lowerBound)
        let numColor = s.attribute(.foregroundColor, at: numOffset, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(kwColor, numColor)
    }

    func testStringLiteralIsColored() {
        let s = CodeHighlighter.highlight("x = \"hi\"", language: "python", theme: theme)
        let r = s.string.range(of: "\"hi\"")!
        let off = s.string.distance(from: s.string.startIndex, to: r.lowerBound)
        let c = s.attribute(.foregroundColor, at: off, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(c)
    }

    func testOutputPreservesExactText() {
        let code = "def f():\n    return 1\n"
        let s = CodeHighlighter.highlight(code, language: "python", theme: theme)
        XCTAssertEqual(s.string, code) // highlighting must never alter characters
    }

    func testCanonicalAliasesResolve() {
        // javascript alias should highlight a keyword the same as "js".
        let s = CodeHighlighter.highlight("const y = 2", language: "javascript", theme: theme)
        let kw = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let numOff = s.string.distance(from: s.string.startIndex, to: s.string.range(of: "2")!.lowerBound)
        let num = s.attribute(.foregroundColor, at: numOff, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(kw, num)
    }
}
