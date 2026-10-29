public import SwiftUI

/// Lets another module show something else in place of a fenced code block, e.g. an Artifact
/// card (ART-01, ADR 0060). `make` returns `nil` to keep the normal code block (CHAT-04).
///
/// Values compare by `id` only, so re-creating the closure with the same `id` (on every
/// transcript update) doesn't invalidate the frozen markdown blocks that read it (ADR 0010).
/// Change the `id` whenever what `make` decides could change.
public struct CodeBlockReplacement: Equatable {
    public let id: AnyHashable
    public let make: @MainActor (_ language: String?, _ code: String) -> AnyView?

    public init(id: some Hashable, make: @escaping @MainActor (_ language: String?, _ code: String) -> AnyView?) {
        self.id = AnyHashable(id)
        self.make = make
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

extension EnvironmentValues {
    /// Replaces fenced code blocks in rendered markdown; `nil` renders every block as code.
    @Entry public var codeBlockReplacement: CodeBlockReplacement? = nil
}

/// A fenced code block, or what `\.codeBlockReplacement` puts in its place.
struct CodeBlockSlot: View {
    let language: String?
    let code: String
    @Environment(\.codeBlockReplacement) private var replacement

    var body: some View {
        if let replaced = replacement?.make(language, code) {
            replaced
        } else {
            CodeBlockView(language: language, code: code)
        }
    }
}
