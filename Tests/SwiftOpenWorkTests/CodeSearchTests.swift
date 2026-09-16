import XCTest
@testable import SwiftOpenWork

final class CodeSearchTests: XCTestCase {

    // MARK: - Glob matching

    func testBareExtensionPatternMatchesAtAnyDepth() {
        // No slash in the pattern → match the basename, so `*.swift` is not root-only.
        XCTAssertTrue(CodeSearch.matches(path: "main.swift", pattern: "*.swift"))
        XCTAssertTrue(CodeSearch.matches(path: "Sources/Engine/Tool.swift", pattern: "*.swift"))
        XCTAssertFalse(CodeSearch.matches(path: "Sources/Engine/Tool.m", pattern: "*.swift"))
    }

    func testDoubleStarSpansDirectories() {
        XCTAssertTrue(CodeSearch.matches(path: "Sources/Engine/Tool.swift", pattern: "Sources/**/*.swift"))
        XCTAssertTrue(CodeSearch.matches(path: "Sources/A/B/C/Deep.swift", pattern: "Sources/**/*.swift"))
        XCTAssertFalse(CodeSearch.matches(path: "Tests/Engine/Tool.swift", pattern: "Sources/**/*.swift"))
    }

    /// `**` has to be able to match nothing at all, or `Sources/**/*.swift` misses direct children.
    func testDoubleStarMatchesZeroSegments() {
        XCTAssertTrue(CodeSearch.matches(path: "Sources/Tool.swift", pattern: "Sources/**/*.swift"))
        XCTAssertTrue(CodeSearch.matches(path: "a.txt", pattern: "**/a.txt"))
    }

    func testSingleStarDoesNotCrossDirectories() {
        XCTAssertTrue(CodeSearch.matches(path: "Sources/Tool.swift", pattern: "Sources/*.swift"))
        XCTAssertFalse(CodeSearch.matches(path: "Sources/Engine/Tool.swift", pattern: "Sources/*.swift"))
    }

    func testQuestionMarkMatchesExactlyOneCharacter() {
        XCTAssertTrue(CodeSearch.matchSegment("a.swift", pattern: "?.swift"))
        XCTAssertFalse(CodeSearch.matchSegment("ab.swift", pattern: "?.swift"))
    }

    func testCharacterClasses() {
        XCTAssertTrue(CodeSearch.matchSegment("a.swift", pattern: "[abc].swift"))
        XCTAssertFalse(CodeSearch.matchSegment("d.swift", pattern: "[abc].swift"))
        XCTAssertTrue(CodeSearch.matchSegment("m.swift", pattern: "[a-z].swift"))
        XCTAssertTrue(CodeSearch.matchSegment("d.swift", pattern: "[!abc].swift"))
        XCTAssertFalse(CodeSearch.matchSegment("a.swift", pattern: "[!abc].swift"))
    }

    /// Backtracking case: a greedy `*` must give characters back so the suffix can match.
    func testStarBacktracks() {
        XCTAssertTrue(CodeSearch.matchSegment("ToolExecutionEngine.swift", pattern: "Tool*Engine.swift"))
        XCTAssertTrue(CodeSearch.matchSegment("aaa.swift", pattern: "*a.swift"))
        XCTAssertFalse(CodeSearch.matchSegment("ToolExecutionEngine.m", pattern: "Tool*Engine.swift"))
    }

    func testEmptyPatternMatchesNothing() {
        XCTAssertFalse(CodeSearch.matches(path: "a.swift", pattern: ""))
        XCTAssertFalse(CodeSearch.matches(path: "a.swift", pattern: "   "))
    }

    func testIgnoredDirectories() {
        XCTAssertTrue(CodeSearch.isIgnored(directory: ".git"))
        XCTAssertTrue(CodeSearch.isIgnored(directory: "node_modules"))
        XCTAssertTrue(CodeSearch.isIgnored(directory: ".build"))
        XCTAssertFalse(CodeSearch.isIgnored(directory: "Sources"))
    }

    // MARK: - Enumeration and content search, against a real temp tree

    private func makeTree() throws -> String {
        let root = NSTemporaryDirectory() + "codesearch-\(UUID().uuidString)"
        let fm = FileManager.default
        for dir in ["Sources/Engine", "Tests", "node_modules/pkg"] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        try "import Foundation\nstruct Alpha {}\n".write(toFile: root + "/Sources/Engine/Alpha.swift", atomically: true, encoding: .utf8)
        try "struct Beta {}\nlet alpha = 1\n".write(toFile: root + "/Sources/Beta.swift", atomically: true, encoding: .utf8)
        try "struct Gamma {}\n".write(toFile: root + "/Tests/GammaTests.swift", atomically: true, encoding: .utf8)
        try "struct Alpha {}\n".write(toFile: root + "/node_modules/pkg/index.swift", atomically: true, encoding: .utf8)
        return root
    }

    func testGlobFindsSwiftFilesAndSkipsIgnoredDirectories() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = CodeSearch.glob(pattern: "**/*.swift", root: root)
        XCTAssertTrue(result.paths.contains("Sources/Engine/Alpha.swift"))
        XCTAssertTrue(result.paths.contains("Sources/Beta.swift"))
        XCTAssertTrue(result.paths.contains("Tests/GammaTests.swift"))
        // node_modules must never be walked.
        XCTAssertFalse(result.paths.contains { $0.contains("node_modules") })
    }

    func testGlobScopedToSubdirectory() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = CodeSearch.glob(pattern: "Sources/**/*.swift", root: root)
        XCTAssertTrue(result.paths.contains("Sources/Beta.swift"))
        XCTAssertFalse(result.paths.contains("Tests/GammaTests.swift"))
    }

    func testGlobReportsTruncation() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = CodeSearch.glob(pattern: "**/*.swift", root: root, limit: 1)
        XCTAssertEqual(result.paths.count, 1)
        XCTAssertTrue(result.truncated)
    }

    func testGrepFindsMatchesWithLineNumbers() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = try CodeSearch.grep(pattern: "struct Alpha", root: root)
        XCTAssertEqual(result.matches.count, 1, "node_modules should not be searched")
        XCTAssertEqual(result.matches.first?.path, "Sources/Engine/Alpha.swift")
        XCTAssertEqual(result.matches.first?.line, 2)
    }

    func testGrepIncludeScopesTheSearch() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let all = try CodeSearch.grep(pattern: "struct", root: root)
        let scoped = try CodeSearch.grep(pattern: "struct", root: root, include: "Tests/**/*.swift")
        XCTAssertGreaterThan(all.matches.count, scoped.matches.count)
        XCTAssertTrue(scoped.matches.allSatisfy { $0.path.hasPrefix("Tests/") })
    }

    func testGrepCaseInsensitivity() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertTrue(try CodeSearch.grep(pattern: "ALPHA", root: root).matches.isEmpty)
        XCTAssertFalse(try CodeSearch.grep(pattern: "ALPHA", root: root, caseInsensitive: true).matches.isEmpty)
    }

    func testGrepRejectsInvalidRegex() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertThrowsError(try CodeSearch.grep(pattern: "struct (", root: root))
    }

    func testFormatSaysSoWhenNothingMatched() {
        let empty = CodeSearch.GrepResult(matches: [], truncated: false, filesSearched: 7)
        XCTAssertTrue(CodeSearch.format(empty, pattern: "zzz").contains("No matches"))
    }
}
