import SwiftUI
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a dead MCP child stdin must not abort the process (EPIPE).
        signal(SIGPIPE, SIG_IGN)

        if let image = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = image
        } else if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "AppIcon.icns", withExtension: nil),
                  let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }

        WindowLayoutStore.observeMainWindowAutosave()
        // Window may not exist yet; configure now and again on the next runloop.
        WindowLayoutStore.configureMainWindowAutosave()
        DispatchQueue.main.async {
            WindowLayoutStore.configureMainWindowAutosave()
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        WindowLayoutStore.configureMainWindowAutosave()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending frame + ensure layout keys are written.
        for window in NSApp.windows where window.frameAutosaveName == WindowLayoutStore.mainWindowAutosaveName {
            window.saveFrame(usingName: WindowLayoutStore.mainWindowAutosaveName)
        }
        UserDefaults.standard.synchronize()
    }
}

@main
public struct OpenWorkSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainView(appState: appState)
                .preferredColorScheme(colorScheme(for: appState.settings.theme))
                .onAppear {
                    WindowLayoutStore.configureMainWindowAutosave()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
        .commands {
            SidebarCommands()

            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    appState.createNewSession()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Quick Open / Spotlight") {
                    appState.isSearchDialogOpen.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("Navigation") {
                Button("Chat & Sessions") {
                    appState.navigationDestination = .chat
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("AI Agents") {
                    appState.navigationDestination = .agents
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Model Providers") {
                    appState.navigationDestination = .providers
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Automations") {
                    appState.navigationDestination = .automations
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Settings") {
                    appState.navigationDestination = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .light: return .light
        case .dark, .midnight, .cyberpunk, .monokai: return .dark
        case .system: return nil
        }
    }
}
