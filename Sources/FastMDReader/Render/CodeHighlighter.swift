import AppKit

/// Native, dependency-free regex tokenizer for a curated language set. This keeps the
/// "no JavaScriptCore for code-only documents" guarantee (spec §2, §10.1). Unknown /
/// unsupported languages fall back to plain monospace. tree-sitter is a v2 upgrade.
enum CodeHighlighter {
    private struct Palette {
        let keyword = NSColor.systemPink
        let type = NSColor.systemTeal
        let string = NSColor.systemRed
        let number = NSColor.systemOrange
        let comment = NSColor.secondaryLabelColor
    }

    private static let keywords: [String: Set<String>] = [
        "swift": ["let","var","func","if","else","for","while","return","struct","class","enum","import","guard","in","self","true","false","nil"],
        "js": ["const","let","var","function","if","else","for","while","return","class","import","export","await","async","true","false","null","undefined"],
        "ts": ["const","let","var","function","if","else","for","while","return","class","import","export","await","async","interface","type","true","false","null"],
        "python": ["def","class","if","elif","else","for","while","return","import","from","as","with","in","not","and","or","True","False","None"],
        "bash": ["if","then","else","fi","for","in","do","done","case","esac","function","return","echo","export"],
        "json": [],
    ]

    private static func canonical(_ lang: String?) -> String? {
        guard let l = lang?.lowercased() else { return nil }
        switch l {
        case "javascript": return "js"
        case "typescript": return "ts"
        case "py": return "python"
        case "sh", "shell", "zsh": return "bash"
        default: return keywords[l] != nil ? l : nil
        }
    }

    static func highlight(_ code: String, language: String?, theme: RenderTheme) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: theme.codeFont, .foregroundColor: theme.textColor]
        let result = NSMutableAttributedString(string: code, attributes: base)
        guard let lang = canonical(language) else { return result } // plain fallback
        let p = Palette()
        let ns = code as NSString

        func color(_ pattern: String, _ c: NSColor, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                result.addAttribute(.foregroundColor, value: c, range: m.range)
            }
        }

        // keywords first, then literals/comments override where they overlap
        for kw in keywords[lang] ?? [] {
            color("\\b\(NSRegularExpression.escapedPattern(for: kw))\\b", p.keyword)
        }
        color("\\b[0-9]+(?:\\.[0-9]+)?\\b", p.number)
        color("\"(?:[^\"\\\\]|\\\\.)*\"", p.string)
        color("'(?:[^'\\\\]|\\\\.)*'", p.string)
        if lang == "python" || lang == "bash" {
            color("#[^\\n]*", p.comment)
        } else {
            color("//[^\\n]*", p.comment)
        }
        return result
    }
}
