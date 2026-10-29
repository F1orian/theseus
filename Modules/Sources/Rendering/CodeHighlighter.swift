import Foundation

/// A small, dependency-free syntax highlighter for read-only code blocks (CHAT-04). It knows
/// strings, comments, numbers and keywords for the languages models write most; anything else
/// renders as plain monospaced text.
public enum CodeHighlighter {
    public enum TokenKind: Sendable, Hashable {
        case keyword
        case string
        case comment
        case number
        case type
    }

    public struct Token: Sendable, Hashable {
        public let range: Range<Int>
        public let kind: TokenKind
    }

    private struct Grammar {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (open: String, close: String)?
        var capitalizedTypes = true
    }

    private static let cFamily: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
        "true", "false", "null", "nil", "class", "struct", "enum", "static", "const", "new", "this",
        "try", "catch", "throw", "throws", "import", "public", "private", "protected", "void", "int",
        "float", "double", "bool", "char", "long", "unsigned", "typedef", "extends", "implements", "interface",
    ]

    private static func grammar(for language: String?) -> Grammar? {
        switch language?.lowercased() {
        case "swift":
            return Grammar(keywords: cFamily.union([
                "let", "var", "func", "guard", "in", "init", "self", "Self", "extension", "protocol", "where",
                "async", "await", "some", "any", "inout", "mutating", "final", "override", "actor", "defer",
                "fileprivate", "internal", "open", "is", "as", "repeat", "associatedtype", "typealias",
            ]), lineComments: ["//"], blockComment: ("/*", "*/"))
        case "python", "py":
            return Grammar(keywords: [
                "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "pass",
                "break", "continue", "None", "True", "False", "async", "await", "global", "nonlocal", "self",
            ], lineComments: ["#"], blockComment: nil)
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            return Grammar(keywords: cFamily.union([
                "let", "var", "function", "const", "async", "await", "export", "from", "of", "in", "typeof",
                "instanceof", "undefined", "yield", "type", "readonly", "as",
            ]), lineComments: ["//"], blockComment: ("/*", "*/"))
        case "c", "cpp", "c++", "objc", "objective-c", "java", "kotlin", "kt", "csharp", "cs", "go", "rust", "rs", "dart", "scala":
            return Grammar(keywords: cFamily.union([
                "fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "match", "func", "package", "var",
                "val", "fun", "object", "when", "is", "in", "namespace", "using", "auto", "template", "go",
                "defer", "chan", "select", "range", "type", "map", "self", "super", "final", "override",
            ]), lineComments: ["//"], blockComment: ("/*", "*/"))
        case "bash", "sh", "shell", "zsh", "console":
            return Grammar(keywords: [
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac",
                "function", "return", "export", "local", "echo", "set", "unset", "source", "sudo", "cd",
            ], lineComments: ["#"], blockComment: nil, capitalizedTypes: false)
        case "ruby", "rb":
            return Grammar(keywords: [
                "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "do", "return",
                "yield", "true", "false", "nil", "self", "require", "attr_accessor", "begin", "rescue",
            ], lineComments: ["#"], blockComment: nil)
        case "sql":
            let words = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create",
                         "table", "join", "left", "right", "inner", "on", "group", "by", "order", "limit", "and",
                         "or", "not", "null", "as", "primary", "key", "index", "having", "distinct"]
            return Grammar(keywords: Set(words + words.map { $0.uppercased() }), lineComments: ["--"], blockComment: ("/*", "*/"), capitalizedTypes: false)
        case "json", "yaml", "yml", "toml":
            return Grammar(keywords: ["true", "false", "null"], lineComments: language == "json" ? [] : ["#"], blockComment: nil, capitalizedTypes: false)
        case "html", "xml", "css", "scss":
            return Grammar(keywords: [], lineComments: [], blockComment: language == "css" || language == "scss" ? ("/*", "*/") : ("<!--", "-->"), capitalizedTypes: false)
        default:
            return nil
        }
    }

    /// Tokens over `code` as UTF-16 offsets would be awkward for SwiftUI; offsets here count
    /// `Character`s, which `AttributedString` indexes directly.
    public static func tokens(in code: String, language: String?) -> [Token] {
        guard let grammar = grammar(for: language) else { return [] }
        let chars = Array(code)
        var tokens: [Token] = []
        var index = 0

        func matches(_ text: String, at position: Int) -> Bool {
            let pattern = Array(text)
            guard !pattern.isEmpty, position + pattern.count <= chars.count else { return false }
            for offset in pattern.indices where chars[position + offset] != pattern[offset] { return false }
            return true
        }

        while index < chars.count {
            let char = chars[index]
            if grammar.lineComments.contains(where: { matches($0, at: index) }) {
                let end = chars[index...].firstIndex(of: "\n") ?? chars.count
                tokens.append(Token(range: index..<end, kind: .comment))
                index = end
                continue
            }
            if let block = grammar.blockComment, matches(block.open, at: index) {
                var end = index + block.open.count
                while end < chars.count, !matches(block.close, at: end) { end += 1 }
                end = min(end + block.close.count, chars.count)
                tokens.append(Token(range: index..<end, kind: .comment))
                index = end
                continue
            }
            if char == "\"" || char == "'" || char == "`" {
                var end = index + 1
                while end < chars.count {
                    if chars[end] == "\\" { end += 2; continue }
                    if chars[end] == char { end += 1; break }
                    if chars[end] == "\n", char != "`" { break }
                    end += 1
                }
                end = min(end, chars.count)
                tokens.append(Token(range: index..<end, kind: .string))
                index = end
                continue
            }
            if char.isNumber, index == 0 || !(chars[index - 1].isLetter || chars[index - 1] == "_") {
                var end = index
                while end < chars.count, chars[end].isHexDigit || chars[end] == "." || chars[end] == "x" || chars[end] == "_" { end += 1 }
                tokens.append(Token(range: index..<end, kind: .number))
                index = end
                continue
            }
            if char.isLetter || char == "_" || char == "@" || char == "$" {
                var end = index + 1
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                let word = String(chars[index..<end])
                if grammar.keywords.contains(word) {
                    tokens.append(Token(range: index..<end, kind: .keyword))
                } else if grammar.capitalizedTypes, word.first?.isUppercase == true, word.count > 1 {
                    tokens.append(Token(range: index..<end, kind: .type))
                }
                index = end
                continue
            }
            index += 1
        }
        return tokens
    }
}
