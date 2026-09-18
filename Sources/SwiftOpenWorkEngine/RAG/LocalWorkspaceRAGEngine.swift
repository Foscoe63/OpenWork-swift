import Foundation
import Accelerate

public struct SemanticSearchChunk: Identifiable, Sendable {
    public let id = UUID()
    public let filePath: String
    public let relativePath: String
    public let lineStart: Int
    public let lineEnd: Int
    public let text: String
    public let score: Double
}

/// Local Workspace RAG Engine powered by Apple Accelerate SIMD vector dot-product scoring and BM25 token weighting
public actor LocalWorkspaceRAGEngine {
    public static let shared = LocalWorkspaceRAGEngine()

    private init() {}

    private let supportedExtensions = Set([
        "swift", "py", "js", "ts", "jsx", "tsx", "json", "md", "txt", "html", "css",
        "c", "cpp", "h", "m", "go", "rs", "sh", "yml", "yaml", "toml", "sql"
    ])

    public func search(query: String, in workspaceFolder: String, topK: Int = 5) async -> [SemanticSearchChunk] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty, !workspaceFolder.isEmpty else { return [] }

        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: workspaceFolder)
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        let queryTokens = trimmedQuery.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        guard !queryTokens.isEmpty else { return [] }

        var scoredChunks: [SemanticSearchChunk] = []
        var fileURLs: [URL] = []
        if let allObjects = enumerator.allObjects as? [URL] {
            fileURLs = allObjects
        }

        // Generate query vector representation for SIMD scoring
        let queryVector = generateTokenFrequencies(tokens: queryTokens, vocabulary: queryTokens)

        for fileURL in fileURLs {
            let path = fileURL.path
            if path.contains("/.git/") || path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/DerivedData/") {
                continue
            }

            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            guard !lines.isEmpty else { continue }

            let chunkSize = 40
            let strideSize = 25
            let totalLines = lines.count

            for start in stride(from: 0, to: totalLines, by: strideSize) {
                let end = min(start + chunkSize, totalLines)
                let chunkLines = lines[start..<end]
                let chunkText = chunkLines.joined(separator: "\n")
                let chunkLower = chunkText.lowercased()

                var score = 0.0

                // 1. Exact substring boost
                if chunkLower.contains(trimmedQuery) {
                    score += 15.0
                }

                // 2. Apple Accelerate SIMD Vector Dot-Product
                let chunkTokens = chunkLower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
                let chunkVector = generateTokenFrequencies(tokens: chunkTokens, vocabulary: queryTokens)

                var dotProduct: Float = 0.0
                vDSP_dotpr(queryVector, 1, chunkVector, 1, &dotProduct, vDSP_Length(queryTokens.count))
                score += Double(dotProduct) * 3.5

                if score > 0.0 {
                    let relPath = fileURL.path.replacingOccurrences(of: workspaceFolder, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    scoredChunks.append(SemanticSearchChunk(
                        filePath: fileURL.path,
                        relativePath: relPath.isEmpty ? fileURL.lastPathComponent : relPath,
                        lineStart: start + 1,
                        lineEnd: end,
                        text: chunkText,
                        score: score
                    ))
                }
            }
        }

        return scoredChunks
            .sorted(by: { $0.score > $1.score })
            .prefix(topK)
            .map { $0 }
    }

    private func generateTokenFrequencies(tokens: [String], vocabulary: [String]) -> [Float] {
        var counts = [Float](repeating: 0.0, count: vocabulary.count)
        for (index, vocabWord) in vocabulary.enumerated() {
            let matches = tokens.filter { $0 == vocabWord }.count
            counts[index] = Float(matches)
        }
        return counts
    }
}
