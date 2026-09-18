import Foundation
import SwiftOpenWorkCore

/// What the engine needs from the running app, and nothing more.
///
/// The engine used to reach for `AppState.shared` directly, which tied it to the app's state and
/// SwiftUI layer. `AppState` conforms to this and registers itself in `EngineHosting` when it is
/// created. Code here must cope with there being no host: a test that never creates the app's
/// state has none.
@MainActor
public protocol EngineHost: AnyObject {
    var settings: AppSettings { get set }
    var providers: [ModelProvider] { get }
    var currentProvider: ModelProvider { get }
    var currentModel: ModelInfo { get }
    func showToast(_ message: String)
    /// Show the preview pane, when the user is on a screen it sits beside.
    func revealPreviewIfWatched()
}

@MainActor
public enum EngineHosting {
    /// The running app's state; nil until it is created.
    public static weak var host: (any EngineHost)?
}
