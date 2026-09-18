import Foundation

extension MCPServerConfig {
    /// Drop invalid CodeGraph argv tokens such as `alwaysLoad` / `true` that make `serve` exit immediately.
    public static func sanitizedStdioArgs(command: String, name: String, args: [String]) -> [String] {
        let isCodegraph = command.lowercased().contains("codegraph")
            || name.lowercased().contains("codegraph")
            || name.lowercased().contains("code_graph")
        guard isCodegraph else { return args }

        var out: [String] = []
        var i = 0
        while i < args.count {
            let tok = args[i]
            switch tok {
            case "serve", "--mcp", "--no-watch":
                out.append(tok)
                i += 1
            case "-p", "--path":
                out.append(tok)
                if i + 1 < args.count {
                    out.append(args[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            default:
                // Drop unknowns (alwaysLoad, true, etc.)
                i += 1
            }
        }
        if !out.contains("serve") { out.insert("serve", at: 0) }
        if !out.contains("--mcp") { out.append("--mcp") }
        return out
    }
}
