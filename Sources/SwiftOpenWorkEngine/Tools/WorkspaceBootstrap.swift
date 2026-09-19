import Foundation

/// Sets up the folder behind a newly created workspace: starter files, a `.gitignore`, and a git
/// repository with the starting point committed.
///
/// Session diffs, agent worktrees and `git_commit` all need a repository, and a workspace created
/// on an empty folder never had one. Only an empty folder is touched: a folder that already holds
/// files is the user's project, and initialising git in it, or dropping files into it, is not the
/// app's call. A folder inside an existing repository is left to that repository.
public enum WorkspaceBootstrap {

    public enum StarterTemplate: String, CaseIterable, Identifiable, Sendable {
        case empty
        case staticSite
        case viteReact
        case swiftUIApp
        case pythonScript

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .empty: return "Empty folder"
            case .staticSite: return "Static website (HTML, CSS, JS)"
            case .viteReact: return "React app (Vite)"
            case .swiftUIApp: return "SwiftUI Mac app (Swift package)"
            case .pythonScript: return "Python script"
            }
        }

        /// Files to write, relative to the workspace folder.
        public func files(projectName: String) -> [String: String] {
            // The name lands inside Swift and Python string literals and HTML, so characters that
            // would end a literal or open a tag are dropped rather than escaped per language.
            let cleaned = String(projectName.filter { !"\"\\<>`$".contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = cleaned.isEmpty ? "My Project" : cleaned
            switch self {
            case .empty:
                return [".gitignore": gitignore(extra: [])]
            case .staticSite:
                return StarterFiles.staticSite(name: name)
            case .viteReact:
                return StarterFiles.viteReact(name: name, packageName: packageName(name))
            case .swiftUIApp:
                return StarterFiles.swiftUIApp(name: name, targetName: swiftIdentifier(name))
            case .pythonScript:
                return StarterFiles.pythonScript(name: name)
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Paths written, relative to the folder.
        public var writtenFiles: [String] = []
        public var initialisedRepository = false
        public var committed = false
        /// Why a step was skipped, for the toast. Nil when everything ran.
        public var note: String?

        public var summary: String {
            var parts: [String] = []
            if !writtenFiles.isEmpty { parts.append("\(writtenFiles.count) starter file\(writtenFiles.count == 1 ? "" : "s")") }
            if initialisedRepository { parts.append(committed ? "git repository with a first commit" : "git repository") }
            var text = parts.isEmpty ? "" : "Set up " + parts.joined(separator: " and ")
            if let note { text += text.isEmpty ? note : ". \(note)" }
            return text
        }
    }

    /// Files macOS or Finder leave in a folder that do not make it the user's project.
    private static let ignorableEntries: Set<String> = [".DS_Store", ".localized"]

    /// True when `folder` is missing or holds nothing but Finder metadata and `ignoring`, which
    /// is for folders the app itself just made there (the staged pipeline's `input`/`output`).
    public static func isEmptyFolder(_ folder: String, ignoring: Set<String> = []) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return !FileManager.default.fileExists(atPath: folder)
        }
        return entries.allSatisfy { ignorableEntries.contains($0) || ignoring.contains($0) }
    }

    /// Write `template` into `folder` and put it under git. Blocking: git runs on the worktree
    /// queue, but callers should still call this off the main thread.
    public static func bootstrap(
        folder: String,
        template: StarterTemplate,
        projectName: String,
        ignoring: Set<String> = []
    ) async -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        guard isEmptyFolder(folder, ignoring: ignoring) else {
            outcome.note = "The folder already had files, so it was left as it was"
            return outcome
        }
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            outcome.note = "Could not create the folder: \(error.localizedDescription)"
            return outcome
        }

        let root = URL(fileURLWithPath: folder)
        for (relative, contents) in template.files(projectName: projectName).sorted(by: { $0.key < $1.key }) {
            let url = root.appendingPathComponent(relative)
            guard !fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
                outcome.writtenFiles.append(relative)
            } catch {
                outcome.note = "Could not write \(relative): \(error.localizedDescription)"
                return outcome
            }
        }

        if (try? await AgentWorktree.git(["rev-parse", "--show-toplevel"], in: root)) != nil {
            outcome.note = "The folder is inside an existing git repository, so no new one was created"
            return outcome
        }
        do {
            try await AgentWorktree.git(["init", "--quiet"], in: root)
            outcome.initialisedRepository = true
        } catch {
            outcome.note = "git init failed; install the Xcode command line tools to get git"
            return outcome
        }
        guard !outcome.writtenFiles.isEmpty else { return outcome }
        do {
            try await AgentWorktree.git(["add", "-A"], in: root)
            try await AgentWorktree.git(["commit", "--quiet", "-m", "Start from the \(template.displayName) template"], in: root)
            outcome.committed = true
        } catch {
            // Usually no user.name/user.email configured. The files are there; the user commits.
            outcome.note = "No first commit: set your git name and email to commit"
        }
        return outcome
    }

    // MARK: - Naming

    /// npm package names: lowercase ASCII, no spaces.
    static func packageName(_ name: String) -> String {
        let lowered = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "app" : collapsed
    }

    /// A Swift target name: letters and digits, not starting with a digit.
    static func swiftIdentifier(_ name: String) -> String {
        let words = name.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        var joined = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        if joined.isEmpty { joined = "App" }
        if joined.first?.isNumber == true { joined = "App" + joined }
        return joined
    }

    static func gitignore(extra: [String]) -> String {
        ([".DS_Store"] + extra).joined(separator: "\n") + "\n"
    }
}

/// The starter files themselves. Each template carries an AGENTS.md so the agent knows how to run
/// and check the project from its first turn.
enum StarterFiles {

    static func staticSite(name: String) -> [String: String] {
        [
            ".gitignore": WorkspaceBootstrap.gitignore(extra: []),
            "AGENTS.md": """
            # \(name)

            A static website: `index.html`, `style.css` and `script.js`, with no build step.

            - Preview it with the built-in preview (`preview_start`); it serves this folder directly.
            - After changing the page, check it with `preview_check` and fix any console errors.
            - Keep it dependency-free unless asked otherwise.

            """,
            "index.html": """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>\(name)</title>
              <link rel="stylesheet" href="style.css">
            </head>
            <body>
              <main>
                <h1>\(name)</h1>
                <p>Edit <code>index.html</code>, or ask the agent to build something here.</p>
                <button id="counter">Clicked 0 times</button>
              </main>
              <script src="script.js"></script>
            </body>
            </html>

            """,
            "style.css": """
            :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
            main { max-width: 40rem; padding: 2rem; text-align: center; }
            button { font: inherit; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; }

            """,
            "script.js": """
            const button = document.getElementById("counter");
            let count = 0;
            button.addEventListener("click", () => {
              count += 1;
              button.textContent = `Clicked ${count} time${count === 1 ? "" : "s"}`;
            });

            """,
        ]
    }

    static func viteReact(name: String, packageName: String) -> [String: String] {
        [
            ".gitignore": WorkspaceBootstrap.gitignore(extra: ["node_modules/", "dist/"]),
            "AGENTS.md": """
            # \(name)

            A React app built with Vite.

            - Install dependencies with `npm install` before the first run.
            - `npm run dev` starts the dev server; the built-in preview (`preview_start`) runs it for you.
            - `npm run build` must pass before a change is done. Check the page with `preview_check`.
            - Components live in `src/`. Keep state local until something needs sharing.

            """,
            "package.json": """
            {
              "name": "\(packageName)",
              "private": true,
              "version": "0.0.0",
              "type": "module",
              "scripts": {
                "dev": "vite",
                "build": "vite build",
                "preview": "vite preview"
              },
              "dependencies": {
                "react": "^19.1.0",
                "react-dom": "^19.1.0"
              },
              "devDependencies": {
                "@vitejs/plugin-react": "^5.0.0",
                "vite": "^7.0.0"
              }
            }

            """,
            "vite.config.js": """
            import { defineConfig } from "vite";
            import react from "@vitejs/plugin-react";

            export default defineConfig({
              plugins: [react()],
            });

            """,
            "index.html": """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>\(name)</title>
            </head>
            <body>
              <div id="root"></div>
              <script type="module" src="/src/main.jsx"></script>
            </body>
            </html>

            """,
            "src/main.jsx": """
            import { StrictMode } from "react";
            import { createRoot } from "react-dom/client";
            import App from "./App.jsx";
            import "./index.css";

            createRoot(document.getElementById("root")).render(
              <StrictMode>
                <App />
              </StrictMode>
            );

            """,
            "src/App.jsx": """
            import { useState } from "react";

            export default function App() {
              const [count, setCount] = useState(0);
              return (
                <main>
                  <h1>\(name)</h1>
                  <p>Edit <code>src/App.jsx</code>, or ask the agent to build something here.</p>
                  <button onClick={() => setCount((c) => c + 1)}>
                    Clicked {count} time{count === 1 ? "" : "s"}
                  </button>
                </main>
              );
            }

            """,
            "src/index.css": """
            :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
            main { max-width: 40rem; padding: 2rem; text-align: center; }
            button { font: inherit; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; }

            """,
        ]
    }

    static func swiftUIApp(name: String, targetName: String) -> [String: String] {
        [
            ".gitignore": WorkspaceBootstrap.gitignore(extra: [".build/", ".swiftpm/", "*.xcodeproj/xcuserdata/"]),
            "AGENTS.md": """
            # \(name)

            A SwiftUI Mac app as a Swift package, so it builds without an Xcode project.

            - `swift build` must pass before a change is done; `build_project` runs it.
            - `swift run` opens the app window; `run_app` and `screenshot_window` let you check it.
            - Views live in `Sources/\(targetName)/`. Target macOS 14 APIs.

            """,
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "\(targetName)",
                platforms: [.macOS(.v14)],
                targets: [
                    .executableTarget(name: "\(targetName)")
                ]
            )

            """,
            "Sources/\(targetName)/\(targetName)App.swift": """
            import SwiftUI
            import AppKit

            @main
            struct \(targetName)App: App {
                init() {
                    // Run from `swift run` there is no app bundle, so ask to be a regular app with
                    // a Dock icon and a window in front.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate()
                }

                var body: some Scene {
                    WindowGroup("\(name)") {
                        ContentView()
                            .frame(minWidth: 360, minHeight: 240)
                    }
                }
            }

            """,
            "Sources/\(targetName)/ContentView.swift": """
            import SwiftUI

            struct ContentView: View {
                @State private var count = 0

                var body: some View {
                    VStack(spacing: 16) {
                        Text("\(name)")
                            .font(.largeTitle)
                        Text("Edit ContentView.swift, or ask the agent to build something here.")
                            .foregroundStyle(.secondary)
                        Button("Clicked \\(count) time\\(count == 1 ? "" : "s")") {
                            count += 1
                        }
                    }
                    .padding(32)
                }
            }

            """,
        ]
    }

    static func pythonScript(name: String) -> [String: String] {
        [
            ".gitignore": WorkspaceBootstrap.gitignore(extra: ["__pycache__/", ".venv/", "*.pyc"]),
            "AGENTS.md": """
            # \(name)

            A Python 3 script.

            - Run it with `python3 main.py`.
            - Use the standard library unless asked otherwise. If a package is needed, create a
              virtual environment in `.venv` and list the package in `requirements.txt`.
            - Tests go in `test_main.py`; run them with `python3 -m unittest`.

            """,
            "main.py": """
            \"\"\"\(name).\"\"\"


            def greet(name: str) -> str:
                return f"Hello, {name}!"


            def main() -> None:
                print(greet("world"))


            if __name__ == "__main__":
                main()

            """,
            "test_main.py": """
            import unittest

            from main import greet


            class GreetTests(unittest.TestCase):
                def test_greets_by_name(self) -> None:
                    self.assertEqual(greet("Ada"), "Hello, Ada!")


            if __name__ == "__main__":
                unittest.main()

            """,
            "requirements.txt": "",
        ]
    }
}
