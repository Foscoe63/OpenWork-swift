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

    private var activeProcess: Process?

    public init() {
        appendLine("$ openwork-swift --version", isError: false)
        appendLine("OpenWork-Swift v1.0.0 (Darwin arm64) - Interactive Workspace Terminal Ready", isError: false)
        appendLine("Type any macOS shell command below (e.g. ls -la, git status, swift build)", isError: false)
    }

    public func execute(command: String, in workingDirectory: String) {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cmd = command.trimmingCharacters(in: .whitespaces)
        appendLine("$ \(cmd)", isError: false)

        isRunning = true
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]

        let dir = workingDirectory.isEmpty ? FileManager.default.currentDirectoryPath : workingDirectory
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
                self?.isRunning = false
                self?.activeProcess = nil
                if proc.terminationStatus != 0 {
                    self?.appendLine("[Process exited with code \(proc.terminationStatus)]", isError: true)
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

    private func appendLine(_ text: String, isError: Bool) {
        lines.append(TerminalLogLine(text: text, isError: isError))
        if lines.count > 1000 {
            lines.removeFirst(lines.count - 1000)
        }
    }
}
