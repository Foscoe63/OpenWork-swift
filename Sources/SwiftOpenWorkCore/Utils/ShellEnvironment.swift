import Foundation

/// The environment child processes run with: the app's own, plus the usual Homebrew, Cargo and
/// user `bin` folders on `PATH` (a GUI app inherits a minimal one), a UTF-8 locale, and `custom`
/// on top. `ToolExecutionEngine.defaultEnvironment` forwards here.
public enum ShellEnvironment {
    public static func standard(custom: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.cargo/bin",
            "\(home)/.local/bin",
            "\(home)/bin"
        ]
        let currentPath = env["PATH"] ?? ""
        var combinedPaths = extraPaths
        for p in currentPath.components(separatedBy: ":") where !p.isEmpty {
            if !combinedPaths.contains(p) {
                combinedPaths.append(p)
            }
        }
        env["PATH"] = combinedPaths.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["HOME"] = home
        for (k, v) in custom {
            env[k] = v
        }
        return env
    }
}
