/// Something a new Chat's composer opens as soon as it's on screen: a widget's camera or mic
/// button, a Shortcut's Voice mode (PLAT-01, PLAT-03). Set `ComposerModel.launchAction`;
/// `ComposerView` carries it out once the model (and so its Capabilities) is known.
public enum ComposerLaunchAction: Sendable, Equatable {
    case camera
    case photos
    case dictation
    case voiceMode
}

extension ComposerModel {
    /// What a launch action turns into for the current model and Server (ADR 0006).
    enum LaunchOutcome: Equatable {
        case camera
        case photos
        case dictation
        case voiceMode
        /// The action isn't possible here; tell the user why.
        case notice(String)
    }

    func launchOutcome(_ action: ComposerLaunchAction, cameraAvailable: Bool) -> LaunchOutcome {
        let name = selectedModel?.name ?? "This model"
        switch action {
        case .camera, .photos:
            guard canAttachPhotos else { return .notice("\(name) can't see images.") }
            if action == .photos { return .photos }
            return cameraAvailable ? .camera : .notice("There's no camera on this device.")
        case .dictation:
            return capabilities.contains(.dictation) ? .dictation : .notice("Dictation isn't available on this Server.")
        case .voiceMode:
            return capabilities.contains(.voiceMode) ? .voiceMode : .notice("Voice mode isn't available on this Server.")
        }
    }
}
