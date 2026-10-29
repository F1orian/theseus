public import ChatDomain
public import DesignSystem
import SwiftUI

extension ResponseActivity.Work {
    /// The working-mouse scene for this kind of work (#185's table, one scene per row).
    public var scene: WorkingMouse.Scene {
        switch self {
        case .thinking: .thinking
        case .stillWriting: .stillWriting
        case .webSearch: .webSearch
        case .readingPage: .readingPage
        case .knowledge: .knowledge
        case .memory: .memory
        case .pastChats: .pastChats
        case .time: .time
        case .image: .image
        case .runningCode: .runningCode
        case .runningCommand: .runningCommand
        case .readingFiles: .readingFiles
        case .writingFiles: .writingFiles
        case .searchingFiles: .searchingFiles
        case .skill: .skill
        case .subAgent: .subAgent
        case .tool: .tool
        case .waitingOnYou: .waitingOnYou
        }
    }
}

extension WorkingMouse {
    /// The scene for `work`, labelled with its plaque for VoiceOver (#185).
    ///
    /// ```swift
    /// WorkingMouse(work: .webSearch)                       // the chat tail
    /// WorkingMouse(work: .runningCommand, size: .large)    // a long-running state
    /// ```
    public init(work: ResponseActivity.Work, size: Size = .compact, scale: Int? = nil) {
        self.init(work.scene, size: size, scale: scale, label: work.accessibilityLabel)
    }
}

#Preview("Every kind of work, compact") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(ResponseActivity.Work.kinds + [.readingPage(host: "example.com"), .tool(name: "get_weather")], id: \.self) { work in
                WorkingIndicator(work: work)
            }
        }
        .padding()
    }
    .mouseBackdrop()
    .themedBackground()
}

#Preview("Every kind of work, large") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ForEach(ResponseActivity.Work.kinds, id: \.self) { work in
                VStack(alignment: .leading, spacing: Spacing.s) {
                    WorkingMouse(work: work, size: .large)
                    Text(work.plaque).plaqueStyle(color: Palette.textSecondary)
                }
            }
        }
        .padding()
    }
    .mouseBackdrop()
    .themedBackground()
}
