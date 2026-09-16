import Foundation

/// Parse `file:line:` diagnostics from tool output so the chat can offer jump actions.
public enum DiagnosticLinkParser {
    public struct Link: Identifiable, Equatable, Sendable {
        public var id: String { "\(file):\(line ?? 0):\(message.prefix(40))" }
        public var file: String
        public var line: Int?
        public var message: String
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^([^\s:][^:\n]*?\.\w+):(\d+)(?::\d+)?:\s*(?:error|warning|note):\s*(.+)$"#,
        options: [.anchorsMatchLines]
    )

    public static func links(in output: String, limit: Int = 12) -> [Link] {
        let range = NSRange(output.startIndex..., in: output)
        var out: [Link] = []
        var seen = Set<String>()
        for match in pattern.matches(in: output, range: range) {
            guard let fileR = Range(match.range(at: 1), in: output),
                  let lineR = Range(match.range(at: 2), in: output),
                  let msgR = Range(match.range(at: 3), in: output) else { continue }
            let file = String(output[fileR])
            let line = Int(output[lineR])
            let message = String(output[msgR])
            let key = "\(file):\(line ?? 0)"
            guard seen.insert(key).inserted else { continue }
            out.append(Link(file: file, line: line, message: message))
            if out.count >= limit { break }
        }
        return out
    }
}
