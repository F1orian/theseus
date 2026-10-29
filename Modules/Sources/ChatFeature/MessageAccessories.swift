public import ChatDomain
public import SwiftUI

/// Views another Feature area attaches to Messages in the transcript, provided by the host app
/// (ADR 0009). The Message actions area (`MessageActionsFeature`) fills these with the action
/// row, the Branch pager and Edit; without them the transcript shows bare Messages.
public struct MessageAccessories {
    /// Below an assistant Response: the action row (MSG-01) and its Branch pager (MSG-04).
    public var response: (@MainActor (ConversationModel, Message) -> AnyView)?
    /// Below a user Message: its Branch pager (MSG-04).
    public var userMessage: (@MainActor (ConversationModel, Message) -> AnyView)?
    /// Extra entries in a user Message's long-press menu, after Copy (e.g. Edit, MSG-05).
    public var userMessageMenu: (@MainActor (ConversationModel, Message) -> AnyView)?

    public init(
        response: (@MainActor (ConversationModel, Message) -> AnyView)? = nil,
        userMessage: (@MainActor (ConversationModel, Message) -> AnyView)? = nil,
        userMessageMenu: (@MainActor (ConversationModel, Message) -> AnyView)? = nil
    ) {
        self.response = response
        self.userMessage = userMessage
        self.userMessageMenu = userMessageMenu
    }
}

extension EnvironmentValues {
    @Entry public var messageAccessories = MessageAccessories()
}
