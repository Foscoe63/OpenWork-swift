import Foundation
import ServiceManagement

/// The "Launch at Login" switch, actually connected to something.
///
/// It was a stored Bool that nothing read: flipping it changed a value in settings.json and
/// nothing else, so the app did not launch at login and there was no way for the user to tell.
/// A switch that reads as a guarantee and delivers nothing is worse than no switch.
public enum LaunchAtLogin {

    /// What macOS currently reports, which is the only authority — the user can revoke this in
    /// System Settings > General > Login Items without the app being told.
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually in force afterwards, which may not be what was asked for:
    /// registration can be refused, or left pending the user's approval in System Settings.
    @discardableResult
    public static func set(_ enabled: Bool) -> Result<Bool, Error> {
        do {
            if enabled {
                // Registering an already-registered service throws; the goal is the end state.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return .success(isEnabled)
        } catch {
            return .failure(error)
        }
    }

    /// A description of the real state, for the UI to show instead of assuming the toggle won.
    public static func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "OpenWork will open when you log in."
        case .requiresApproval: return "Waiting for approval in System Settings › General › Login Items."
        case .notRegistered: return "OpenWork will not open at login."
        case .notFound: return "macOS could not find this app's login item. Unavailable for unsigned or relocated builds."
        @unknown default: return "Login item state unknown."
        }
    }
}
