import Foundation

/// The prompts a new chat offers, chosen from what is in the workspace.
///
/// An empty folder wants ideas for something to build; a project wants to be explained, run,
/// debugged and tested — in the words that fit its kind, so "run it" means the preview for a web
/// app and a build plus screenshot for a Mac app. Only the top level is read, so this is cheap
/// enough to recompute whenever the workspace changes.
public enum StarterSuggestions {

    public struct Suggestion: Identifiable, Equatable, Sendable {
        public var id: String { title }
        public var title: String
        public var subtitle: String
        public var icon: String
        public var prompt: String
    }

    public enum ProjectKind: Equatable, Sendable {
        case empty
        case web
        case swift
        case python
        case other
    }

    /// Entries that do not make a folder a project: Finder metadata, git, the starter's own
    /// scaffolding and the staged pipeline's folders.
    private static let scaffolding: Set<String> = [
        ".DS_Store", ".localized", ".git", ".gitignore", "AGENTS.md", "input", "output",
    ]

    public static func kind(ofFolder folder: String) -> ProjectKind {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return .empty }
        let names = Set(entries)
        if names.subtracting(scaffolding).isEmpty { return .empty }
        if names.contains("package.json") || names.contains("index.html") { return .web }
        if names.contains("Package.swift") || entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return .swift
        }
        if names.contains("pyproject.toml") || names.contains("requirements.txt")
            || entries.contains(where: { $0.hasSuffix(".py") }) {
            return .python
        }
        return .other
    }

    public static func suggestions(forFolder folder: String) -> [Suggestion] {
        suggestions(for: kind(ofFolder: folder))
    }

    public static func suggestions(for kind: ProjectKind) -> [Suggestion] {
        guard kind != .empty else { return buildIdeas }
        let run: Suggestion
        switch kind {
        case .web:
            run = Suggestion(
                title: "Run it and look",
                subtitle: "Start the preview, check the page and its console",
                icon: "play.rectangle",
                prompt: "Start this project in the preview with preview_start, then use preview_check to look at the page. Tell me what it shows and fix any console errors you find."
            )
        case .swift:
            run = Suggestion(
                title: "Build and run it",
                subtitle: "Build, launch, and show a screenshot",
                icon: "play.rectangle",
                prompt: "Build this project with build_project and fix any errors. Then launch it with run_app, take a screenshot_window, and tell me what the app shows."
            )
        case .python:
            run = Suggestion(
                title: "Run it and its tests",
                subtitle: "See what it does and whether the tests pass",
                icon: "play.rectangle",
                prompt: "Work out how this project is run, run it, and run its tests. Tell me what it does and fix anything that fails."
            )
        case .empty, .other:
            run = Suggestion(
                title: "Get it running",
                subtitle: "Find how it builds and runs, then do it",
                icon: "play.rectangle",
                prompt: "Work out how this project is built and run, do it, and tell me what happened. Fix anything that fails."
            )
        }
        return [
            Suggestion(
                title: "Explain this project",
                subtitle: "What it does, how it is laid out, where to start",
                icon: "text.book.closed",
                prompt: "Explain this project to me: what it does, how the code is organised, and which files I would change first to work on it. Keep it short."
            ),
            run,
            Suggestion(
                title: "Find and fix a bug",
                subtitle: "Build and test it, then fix what is broken",
                icon: "ladybug",
                prompt: "Look for a real bug in this project: build it and run the tests, read the code paths most likely to fail, then fix the most important problem you find and show me the change."
            ),
            Suggestion(
                title: "Add tests",
                subtitle: "Cover the most important untested code",
                icon: "checkmark.seal",
                prompt: "Find the most important code in this project that has no tests, add tests for it in the project's existing style, and run them."
            ),
        ]
    }

    /// For an empty folder: small, finishable things that show what the agent can do.
    public static let buildIdeas: [Suggestion] = [
        Suggestion(
            title: "A landing page",
            subtitle: "One page with a hero, features and a sign-up form",
            icon: "globe",
            prompt: "Build a single-page landing site here with plain HTML, CSS and JavaScript: a hero section, three feature cards, and an email sign-up form that validates the address. Show it in the preview when it works."
        ),
        Suggestion(
            title: "A to-do app",
            subtitle: "Add, check off and filter tasks, saved in the browser",
            icon: "checklist",
            prompt: "Build a to-do app here as a static web page: add tasks, check them off, filter all/active/done, and keep them in localStorage. Show it in the preview when it works."
        ),
        Suggestion(
            title: "A small game",
            subtitle: "Snake in the browser, with a score",
            icon: "gamecontroller",
            prompt: "Build Snake here as a static web page using a canvas: arrow keys to steer, a score, and a restart button. Show it in the preview when it works."
        ),
        Suggestion(
            title: "A Mac app",
            subtitle: "A SwiftUI app you can build and run",
            icon: "macwindow",
            prompt: "Create a small SwiftUI Mac app here as a Swift package: a window with a text field and a list that remembers what I add. Build it, run it and show me a screenshot."
        ),
    ]
}
