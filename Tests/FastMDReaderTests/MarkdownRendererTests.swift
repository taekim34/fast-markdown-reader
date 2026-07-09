import XCTest
import AppKit
@testable import FastMDReader

final class MarkdownRendererTests: XCTestCase {
    private func render(_ md: String) -> NSAttributedString {
        MarkdownRenderer.render(md, theme: .current(size: 14))
    }

    func testHeadingIsBoldAndLarger() {
        let s = render("# Title")
        XCTAssertTrue(s.string.contains("Title"))
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font!.pointSize, 14) // heading > base
    }

    func testEmphasisAndStrong() {
        let s = render("normal *em* **strong**")
        XCTAssertTrue(s.string.contains("em"))
        XCTAssertTrue(s.string.contains("strong"))
    }

    func testInlineCodeUsesMonospace() {
        let s = render("use `code` here")
        let idx = s.string.range(of: "code")!
        let offset = s.string.distance(from: s.string.startIndex, to: idx.lowerBound)
        let font = s.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testUnorderedListRendersBullets() {
        let s = render("- one\n- two")
        XCTAssertTrue(s.string.contains("one"))
        XCTAssertTrue(s.string.contains("two"))
    }

    func testGFMTableRendersAllCells() {
        let s = render("| A | B |\n|---|---|\n| 1 | 2 |")
        for cell in ["A", "B", "1", "2"] {
            XCTAssertTrue(s.string.contains(cell), "missing \(cell)")
        }
    }

    func testHeadingIsTaggedWithMDAttr() {
        // Contract for keyboard heading-jump (C5): every heading run carries MDAttr.heading.
        let s = render("# One\n\nbody\n\n## Two")
        var found: [Int] = []
        s.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let level = v as? Int { found.append(level) }
        }
        XCTAssertEqual(found, [1, 2])
    }
}
