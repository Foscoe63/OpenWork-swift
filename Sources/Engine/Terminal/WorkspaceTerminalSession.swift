import Foundation
import Combine

public struct TerminalLogLine: Identifiable, Hashable {
    public let id = UUID()
    public let text: String
    public let isError: Bool
    public let timestamp = Date()
}

@MainActor
public final class WorkspaceTerminalSession: ObservableObject {
    public static let shared = WorkspaceTerminalSession()

    @Published public var lines: [TerminalLogLine] = []
    @Published public var isRunning: Bool = false
    @Published public var currentCommand: String = ""
    @Published public var commandHistory: [String] = []
    @Published public var activeShellName: String = "zsh"

    private var activeProcess: Process?

    public init() {
        let settings = PersistenceManager.shared.loadSettings()
        let shell = (settings.terminalShell as NSString).lastPathComponent
        self.activeShellName = shell.isEmpty ? "zsh" : shell
        
        appendLine("OpenWork-Swift Interactive Terminal (\(activeShellName))", isError: false)
        appendLine("Type any command (e.g. ls -la, git status, cargo, swift build, python3)", isError: false)
        appendLine("----------------------------------------------------------------------", isError: false)
    }

    public func execute(command: String, in workingDirectory: String, customShell: String? = nil) {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cmd = command.trimmingCharacters(in: .whitespaces)
        
        if !commandHistory.contains(cmd) {
            commandHistory.append(cmd)
        }

        let settings = PersistenceManager.shared.loadSettings()
        let shellPath = customShell ?? (settings.terminalShell.isEmpty ? "/bin/zsh" : settings.terminalShell)
        self.activeShellName = (shellPath as NSString).lastPathComponent

        let folderName = ((workingDirectory as NSString).expandingTildeInPath as NSString).lastPathComponent
        appendLine("[\(folderName)] $ \(cmd)", isError: false)

        isRunning = true
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", cmd]
        process.environment = ToolExecutionEngine.defaultEnvironment(custom: settings.customEnvironmentVariables)

        let dir = workingDirectory.isEmpty ? FileManager.default.currentDirectoryPath : (workingDirectory as NSString).expandingTildeInPath
        process.currentDirectoryURL = URL(fileURLWithPath: dir)

        process.standardOutput = pipe
        process.standardError = errPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                    self?.appendLine(line, isError: false)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                    self?.appendLine(line, isError: true)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                pipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.isRunning = false
                self?.activeProcess = nil
                if proc.terminationStatus != 0 {
                    self?.appendLine("[Exited with code \(proc.terminationStatus)]", isError: true)
                }
            }
        }

        self.activeProcess = process

        do {
            try process.run()
        } catch {
            appendLine("Execution error: \(error.localizedDescription)", isError: true)
            isRunning = false
            activeProcess = nil
        }
    }

    public func terminate() {
        activeProcess?.terminate()
        activeProcess = nil
        isRunning = false
        appendLine("[Process terminated by user]", isError: true)
    }

    public func clear() {
        lines.removeAll()
    }

    public func appendLine(_ text: String, isError: Bool) {
        lines.append(TerminalLogLine(text: text, isError: isError))
        if lines.count > 1500 {
            lines.removeFirst(lines.count - 1500)
        }
    }
}
