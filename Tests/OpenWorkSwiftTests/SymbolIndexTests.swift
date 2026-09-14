import XCTest
@testable import OpenWorkSwift

/// "Where is X defined" answered by grep costs two or three hops and returns every call site
/// alongside the one declaration. This indexes declarations only. It is a regex scan, not a
/// compiler — the tests below pin both what it catches and what it honestly does not.
final class SymbolIndexTests: XCTestCase {

    private func scan(_ content: String, ext: String, path: String = "F") -> [SymbolIndex.Symbol] {
        SymbolIndex.scan(path: path, content: content, ext: ext)
    }

    // MARK: - Swift

    func testFindsSwiftDeclarations() {
        let symbols = scan("""
        public struct Parser {
            public let source: String
            public func parse() -> Int { 0 }
        }
        public typealias Token = String
        extension Parser {}
        actor Worker {}
        """, ext: "swift")

        func kinds(_ name: String) -> Set<SymbolIndex.Kind> {
            Set(symbols.filter { $0.name == name }.map(\.kind))
        }
        XCTAssertEqual(kinds("Parser"), [.type, .exten], "declared once and extended once")
        XCTAssertEqual(kinds("source"), [.property])
        XCTAssertEqual(kinds("parse"), [.function])
        XCTAssertEqual(kinds("Token"), [.alias])
        XCTAssertEqual(kinds("Worker"), [.type])
    }

    /// An unanchored `func (\w+)` matches closure signatures and prose in comments.
    func testDoesNotMatchACallSiteOrAComment() {
        let symbols = scan("""
        // func parse() is declared elsewhere
        let result = parse()
        callback { parse() }
        """, ext: "swift")
        XCTAssertFalse(symbols.contains { $0.name == "parse" && $0.kind == .function })
    }

    func testOneDeclarationPerLine() {
        // `public struct Foo` must not also register as a property via the var/let pattern.
        let symbols = scan("public struct Foo {}", ext: "swift")
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols.first?.kind, .type)
    }

    func testRecordsTheLineNumberAndTheDeclarationText() {
        let symbols = scan("import Foundation\n\nfinal class Engine {}", ext: "swift")
        let engine = symbols.first { $0.name == "Engine" }
        XCTAssertEqual(engine?.line, 3)
        XCTAssertEqual(engine?.text, "final class Engine {}")
    }

    // MARK: - Other languages

    func testFindsPythonDeclarations() {
        let symbols = scan("class Handler:\n    async def run(self):\n        pass", ext: "py")
        XCTAssertEqual(symbols.map(\.name).sorted(), ["Handler", "run"])
    }

    func testFindsTypeScriptDeclarations() {
        let symbols = scan("""
        export interface Options {}
        export async function load() {}
        export const VERSION = "1"
        export type Id = string
        """, ext: "ts")
        XCTAssertEqual(Set(symbols.map(\.name)), ["Options", "load", "VERSION", "Id"])
    }

    func testFindsGoDeclarationsIncludingMethods() {
        let symbols = scan("type Server struct{}\nfunc (s *Server) Start() {}\nfunc New() {}", ext: "go")
        XCTAssertEqual(Set(symbols.map(\.name)), ["Server", "Start", "New"])
    }

    func testFindsRustDeclarations() {
        let symbols = scan("pub struct Config;\npub async fn load() {}\nimpl Config {}", ext: "rs")
        XCTAssertEqual(Set(symbols.map(\.name)), ["Config", "load"])
    }

    func testIgnoresFileTypesItDoesNotUnderstand() {
        XCTAssertTrue(scan("anything at all", ext: "bin").isEmpty)
        XCTAssertFalse(SymbolIndex.handles(extension: "bin"))
        XCTAssertTrue(SymbolIndex.handles(extension: "Swift"))
    }

    // MARK: - Lookup

    private func makeRepo() throws -> String {
        let root = NSTemporaryDirectory() + "symbols-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
        try """
        public struct Parser {
            public var parserOptions: Int = 0
        }
        """.write(toFile: root + "/Sources/Parser.swift", atomically: true, encoding: .utf8)
        try """
        func useParser() { _ = Parser() }
        struct ParserHelper {}
        """.write(toFile: root + "/Sources/Other.swift", atomically: true, encoding: .utf8)
        return root
    }

    func testExactMatchesComeFirstAndLongerNamesDoNotBuryThem() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let index = SymbolIndex()
        let hits = await index.lookup(name: "Parser", root: root)
        XCTAssertEqual(hits.first?.name, "Parser")
        XCTAssertEqual(hits.first?.kind, .type)
        XCTAssertFalse(hits.contains { $0.name == "ParserHelper" },
                       "an exact match exists, so substring matches must not be mixed in")
    }

    func testSubstringMatchIsTheFallbackWhenNothingMatchesExactly() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let index = SymbolIndex()
        let hits = await index.lookup(name: "parserop", root: root)
        XCTAssertEqual(hits.map(\.name), ["parserOptions"])
    }

    func testCallSitesAreNotReturned() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let index = SymbolIndex()
        let hits = await index.lookup(name: "Parser", root: root)
        XCTAssertTrue(hits.allSatisfy { $0.kind == .type || $0.kind == .exten },
                      "`_ = Parser()` inside useParser is a call, not a declaration")
    }

    /// Finding nothing must not read as proof the symbol does not exist.
    func testEmptyResultSaysItIsNotExhaustive() {
        let text = SymbolIndex.format([], name: "Missing")
        XCTAssertTrue(text.contains("not exhaustive"))
        XCTAssertTrue(text.contains("grep"))
    }

    func testFormatShowsKindPathAndLine() {
        let text = SymbolIndex.format(
            [.init(name: "Parser", kind: .type, path: "Sources/P.swift", line: 12, text: "struct Parser {")],
            name: "Parser"
        )
        XCTAssertTrue(text.contains("[type] Sources/P.swift:12: struct Parser {"))
    }
}
