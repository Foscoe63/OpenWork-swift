import Foundation

/// A persistent, ranked index over a workspace's source files.
///
/// The previous `workspace_semantic_search` rescanned every file on every query and scored with
/// raw token-frequency cosine similarity, which rewards long chunks and common words. This builds
/// an inverted index once, keeps it until files change, and ranks with BM25 — which discounts
/// terms that appear everywhere and normalises for chunk length.
///
/// It is lexical, not embedding-based: it will not connect "authentication" to a file that only
/// ever says "login". Swapping in embeddings later is a change to `score`, not to the storage or
/// the tool surface — the chunking and incremental invalidation stay as they are.
public actor CodeIndex {
    public static let shared = CodeIndex()

    /// Lines per chunk. Small enough to point at a specific function, large enough to carry
    /// surrounding context into the result.
    public static let chunkLines = 40
    /// Files larger than this are skipped: generated bundles and data blobs add noise, not signal.
    public static let maxFileBytes = 1_500_000

    public struct Chunk: Sendable, Equatable {
        public var path: String
        public var startLine: Int
        public var endLine: Int
        public var text: String
    }

    public struct Hit: Sendable, Equatable {
        public var chunk: Chunk
        public var score: Double
    }

    private struct Indexed {
        var chunks: [Chunk]
        /// term -> chunk indices containing it
        var postings: [String: [Int]]
        /// per-chunk token counts
        var lengths: [Int]
        var averageLength: Double
        /// path -> modification date, for incremental invalidation
        var stamps: [String: Date]
    }

    private var cache: [String: Indexed] = [:]

    private init() {}

    // MARK: - Tokenisation

    /// Split identifiers the way code is actually written: `parseToolCall` and `parse_tool_call`
    /// both yield parse/tool/call, so a query in either style finds both.
    public nonisolated static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if current.count > 1 { tokens.append(current.lowercased()) }
            current = ""
        }

        for char in text {
            if char.isLetter || char.isNumber {
                if char.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                    flush()
                }
                current.append(char)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    // MARK: - Building

    /// Build or refresh the index for `root`. Unchanged files reuse their existing chunks.
    @discardableResult
    public func build(root: String, fileExtensions: Set<String>? = nil) -> Int {
        let paths = CodeSearch.glob(pattern: "**", root: root, limit: 20_000).paths
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        var stamps: [String: Date] = [:]
        var chunks: [Chunk] = []

        let existing = cache[root]
        for relative in paths {
            let ext = (relative as NSString).pathExtension.lowercased()
            if let fileExtensions, !fileExtensions.contains(ext) { continue }
            guard Self.isTextExtension(ext) else { continue }

            let full = rootPrefix + relative
            let attributes = try? FileManager.default.attributesOfItem(atPath: full)
            if let size = attributes?[.size] as? Int, size > Self.maxFileBytes { continue }
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            stamps[relative] = modified

            // Unchanged since the last build: reuse rather than re-reading.
            if let existing, existing.stamps[relative] == modified {
                chunks.append(contentsOf: existing.chunks.filter { $0.path == relative })
                continue
            }
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            chunks.append(contentsOf: Self.chunk(path: relative, content: content))
        }

        var postings: [String: [Int]] = [:]
        var lengths: [Int] = []
        for (index, chunk) in chunks.enumerated() {
            let tokens = Self.tokenize(chunk.text)
            lengths.append(tokens.count)
            for term in Set(tokens) {
                postings[term, default: []].append(index)
            }
        }
        let average = lengths.isEmpty ? 1 : Double(lengths.reduce(0, +)) / Double(lengths.count)

        cache[root] = Indexed(
            chunks: chunks,
            postings: postings,
            lengths: lengths,
            averageLength: max(1, average),
            stamps: stamps
        )
        return chunks.count
    }

    static func chunk(path: String, content: String) -> [Chunk] {
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }
        var out: [Chunk] = []
        var start = 0
        while start < lines.count {
            let end = min(start + chunkLines, lines.count)
            let text = lines[start..<end].joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(Chunk(path: path, startLine: start + 1, endLine: end, text: text))
            }
            start = end
        }
        return out
    }

    static func isTextExtension(_ ext: String) -> Bool {
        [
            "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py", "rb", "java",
            "kt", "kts", "js", "jsx", "ts", "tsx", "sh", "bash", "zsh", "yml", "yaml", "json",
            "toml", "md", "txt", "cfg", "ini", "gradle", "podspec", "plist", "xcconfig", "sql",
        ].contains(ext)
    }

    // MARK: - Searching

    /// BM25 over the indexed chunks. Builds the index on first use for a root.
    public func search(query: String, root: String, topK: Int = 8) -> [Hit] {
        if cache[root] == nil { _ = build(root: root) }
        guard let index = cache[root], !index.chunks.isEmpty else { return [] }

        let terms = Set(Self.tokenize(query))
        guard !terms.isEmpty else { return [] }

        // BM25 constants: k1 damps repeated terms, b controls length normalisation.
        let k1 = 1.5
        let b = 0.75
        let total = Double(index.chunks.count)

        var scores: [Int: Double] = [:]
        for term in terms {
            guard let postings = index.postings[term] else { continue }
            let documentFrequency = Double(postings.count)
            // A term in nearly every chunk carries almost no information.
            let idf = log(1 + (total - documentFrequency + 0.5) / (documentFrequency + 0.5))
            for chunkIndex in postings {
                let tokens = Self.tokenize(index.chunks[chunkIndex].text)
                let frequency = Double(tokens.filter { $0 == term }.count)
                guard frequency > 0 else { continue }
                let length = Double(index.lengths[chunkIndex])
                let denominator = frequency + k1 * (1 - b + b * length / index.averageLength)
                scores[chunkIndex, default: 0] += idf * (frequency * (k1 + 1)) / denominator
            }
        }

        return scores
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(topK)
            .map { Hit(chunk: index.chunks[$0.key], score: $0.value) }
    }

    public func invalidate(root: String) {
        cache.removeValue(forKey: root)
    }

    public func indexedChunkCount(root: String) -> Int {
        cache[root]?.chunks.count ?? 0
    }

    // MARK: - Rendering

    public nonisolated static func format(_ hits: [Hit], query: String) -> String {
        guard !hits.isEmpty else {
            return "No indexed content matches \"\(query)\". Try `grep` for an exact string."
        }
        return hits.map { hit in
            "\(hit.chunk.path):\(hit.chunk.startLine)-\(hit.chunk.endLine)\n\(hit.chunk.text)"
        }.joined(separator: "\n\n---\n\n")
    }
}
