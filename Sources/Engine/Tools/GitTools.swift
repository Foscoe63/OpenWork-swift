import Foundation

/// Read-only git access for the agent.
///
/// "What did you change?" is the central question of a coding turn, and without `git diff` the
/// only way to answer it was to re-read files and hope. These are deliberately read-only:
/// committing is the user's decision, not something an agent should reach for on its own.
public enum GitTools {

    public struct Output: Sendable {
        public var text: String
        public var isRepository: Bool
    }

    /// Cap on captured output; a diff of a large refactor otherwise swamps the context window.
    public static let maxOutputCharacters = 30_000

    public static func isRepository(_ folder: String) -> Bool {
        run(["rev-parse", "--is-inside-work-tree"], in: folder) != nil
    }

    public static func status(in folder: String) -> Output {
        guard let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return Output(text: notARepository(folder), isRepository: false)
        }
        let porcelain = run(["status", "--porcelain"], in: folder) ?? ""
        let lines = porcelain.split(separator: "\n").map(String.init)
        if lines.isEmpty {
            return Output(text: "On branch \(branch). Working tree clean.", isRepository: true)
        }
        let body = lines.map { line -> String in
            let code = String(line.prefix(2))
            let path = String(line.dropFirst(3))
            return "  \(describe(code))  \(path)"
        }
        return Output(
            text: "On branch \(branch). \(lines.count) change(s):\n" + body.joined(separator: "\n"),
            isRepository: true
        )
    }

    /// Unified diff. `staged` shows the index instead of the working tree.
    public static func diff(in folder: String, path: String? = nil, staged: Bool = false) -> Output {
        guard isRepository(folder) else {
            return Output(text: notARepository(folder), isRepository: false)
        }
        var args = ["diff"]
        if staged { args.append("--staged") }
        // `--` keeps a path that looks like a flag from being parsed as one.
        if let path, !path.isEmpty { args.append(contentsOf: ["--", path]) }

        let raw = run(args, in: folder) ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let scope = staged ? "staged changes" : "unstaged changes"
            return Output(text: "No \(scope)" + (path.map { " under \($0)" } ?? "") + ".", isRepository: true)
        }
        return Output(text: clip(raw), isRepository: true)
    }

    public static func log(in folder: String, count: Int = 10) -> Output {
        guard isRepository(folder) else {
            return Output(text: notARepository(folder), isRepository: false)
        }
        let limit = max(1, min(count, 100))
        let raw = run(["log", "--oneline", "-n", String(limit)], in: folder) ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Output(text: "No commits yet.", isRepository: true)
        }
        return Output(text: clip(raw), isRepository: true)
    }

    // MARK: - Internals

    static func describe(_ code: String) -> String {
        // Porcelain codes are two columns: index status, then worktree status.
        if code.hasPrefix("??") { return "untracked" }
        let letters = Set(code.replacingOccurrences(of: " ", with: ""))
        if letters.contains("D") { return "deleted  " }
        if letters.contains("A") { return "added    " }
        if letters.contains("R") { return "renamed  " }
        if letters.contains("M") { return "modified " }
        return code.trimmingCharacters(in: .whitespaces).padding(toLength: 9, withPad: " ", startingAt: 0)
    }

    static func clip(_ text: String) -> String {
        guard text.count > maxOutputCharacters else { return text }
        return String(text.prefix(maxOutputCharacters))
            + "\n\n[output clipped at \(maxOutputCharacters) characters — narrow with a path argument]"
    }

    static func notARepository(_ folder: String) -> String {
        "\(folder) is not a git repository, so there is no history to read. Use file tools instead."
    }

    /// Run git, returning nil on any non-zero exit.
    static func run(_ args: [String], in folder: String) -> String? {
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ToolExecutionEngine.defaultEnvironment()

        let out = Pipe()
        process.standardOutput = out
        // Never attach an undrained stderr pipe — git can be chatty and a full pipe buffer
        // deadlocks the child. Errors surface as a non-zero exit, which is all we need.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a large diff fills the pipe buffer and blocks git otherwise.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
