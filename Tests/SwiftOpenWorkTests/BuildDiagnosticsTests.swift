import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

final class BuildDiagnosticsTests: XCTestCase {

    // MARK: - Compiler diagnostics

    func testParsesSwiftCompilerError() {
        let line = "/repo/Sources/A.swift:12:5: error: cannot find 'foo' in scope"
        let d = BuildDiagnostics.parseLine(line, relativeTo: "/repo")
        XCTAssertEqual(d?.file, "Sources/A.swift")
        XCTAssertEqual(d?.line, 12)
        XCTAssertEqual(d?.column, 5)
        XCTAssertEqual(d?.severity, .error)
        XCTAssertEqual(d?.message, "cannot find 'foo' in scope")
    }

    func testParsesWarningAndNote() {
        XCTAssertEqual(
            BuildDiagnostics.parseLine("/r/B.swift:3:1: warning: unused variable")?.severity, .warning
        )
        XCTAssertEqual(
            BuildDiagnostics.parseLine("/r/B.swift:4:1: note: declared here")?.severity, .note
        )
    }

    func testParsesDiagnosticWithoutColumn() {
        let d = BuildDiagnostics.parseLine("/r/C.swift:9: error: something broke")
        XCTAssertEqual(d?.line, 9)
        XCTAssertNil(d?.column)
    }

    func testIgnoresOrdinaryOutput() {
        XCTAssertNil(BuildDiagnostics.parseLine("Compiling module Foo"))
        XCTAssertNil(BuildDiagnostics.parseLine("Build complete!"))
        XCTAssertNil(BuildDiagnostics.parseLine(""))
    }

    // MARK: - Test-framework failures

    func testParsesXCTestFailure() {
        let line = "/repo/Tests/ATests.swift:42: error: -[ATests testThing] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")"
        let d = BuildDiagnostics.parseLine(line, relativeTo: "/repo")
        XCTAssertEqual(d?.file, "Tests/ATests.swift")
        XCTAssertEqual(d?.line, 42)
        XCTAssertEqual(d?.severity, .error)
        XCTAssertTrue(d?.message.contains("testThing") == true)
    }

    func testParsesSwiftTestingFailure() {
        let line = "✘ Test \"reuses one process\" recorded an issue at McpTests.swift:88:9: Expectation failed"
        let d = BuildDiagnostics.parseLine(line)
        XCTAssertEqual(d?.file, "McpTests.swift")
        XCTAssertEqual(d?.line, 88)
        XCTAssertEqual(d?.column, 9)
        XCTAssertTrue(d?.message.contains("Expectation failed") == true)
    }

    // MARK: - Whole-output parsing

    private let sampleFailure = """
    Compiling SwiftOpenWork
    /repo/Sources/A.swift:12:5: error: cannot find 'foo' in scope
    /repo/Sources/A.swift:12:5: error: cannot find 'foo' in scope
    /repo/Sources/B.swift:3:1: warning: unused variable 'x'
    /repo/Sources/A.swift:4:9: error: missing argument
    error: fatalError
    """

    func testParseDeduplicatesRepeatedDiagnostics() {
        let all = BuildDiagnostics.parse(sampleFailure, relativeTo: "/repo")
        let fooErrors = all.filter { $0.message.contains("cannot find 'foo'") }
        XCTAssertEqual(fooErrors.count, 1, "the same error repeats once per target")
    }

    func testParseSortsErrorsBeforeWarnings() {
        let all = BuildDiagnostics.parse(sampleFailure, relativeTo: "/repo")
        let firstWarningIndex = all.firstIndex { $0.severity == .warning } ?? all.count
        let lastErrorIndex = all.lastIndex { $0.severity == .error } ?? 0
        XCTAssertLessThan(lastErrorIndex, firstWarningIndex)
    }

    func testSummaryLeadsWithTheVerdictAndListsErrors() {
        let summary = BuildDiagnostics.summarize(
            command: "swift build", exitCode: 1, output: sampleFailure, root: "/repo"
        )
        XCTAssertTrue(summary.hasPrefix("`swift build` failed"))
        XCTAssertTrue(summary.contains("2 error(s)"))
        XCTAssertTrue(summary.contains("Sources/A.swift:12:5"))
        XCTAssertFalse(summary.contains("Compiling SwiftOpenWork"), "noise should be dropped")
    }

    func testSuccessSummaryMentionsWarningCount() {
        let summary = BuildDiagnostics.summarize(
            command: "swift build",
            exitCode: 0,
            output: "/r/B.swift:3:1: warning: unused variable 'x'\nBuild complete!"
        )
        XCTAssertTrue(summary.contains("succeeded"))
        XCTAssertTrue(summary.contains("1 warning"))
    }

    /// Linker errors and crashes produce no file:line, and the tail is the only explanation.
    func testFailureWithNoDiagnosticsFallsBackToTheTail() {
        let output = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\nld: symbol(s) not found"
        let summary = BuildDiagnostics.summarize(command: "swift build", exitCode: 1, output: output)
        XCTAssertTrue(summary.contains("No file-level diagnostics"))
        XCTAssertTrue(summary.contains("ld: symbol(s) not found"))
        XCTAssertFalse(summary.contains("line 1\n"), "only the tail should be included")
    }

    func testManyErrorsAreCapped() {
        let output = (1...60).map { "/r/F\($0).swift:1:1: error: boom \($0)" }.joined(separator: "\n")
        let summary = BuildDiagnostics.summarize(
            command: "swift build", exitCode: 1, output: output, maxDiagnostics: 5
        )
        XCTAssertTrue(summary.contains("55 more error(s)"))
    }

    // MARK: - Command selection

    func testCommandForSwiftPackage() {
        XCTAssertEqual(BuildDiagnostics.command(forProjectKinds: ["Swift package"], action: .build), "swift build")
        XCTAssertEqual(BuildDiagnostics.command(forProjectKinds: ["Swift package"], action: .test), "swift test")
    }

    func testCommandForOtherEcosystems() {
        XCTAssertEqual(BuildDiagnostics.command(forProjectKinds: ["Go module"], action: .test), "go test ./...")
        XCTAssertEqual(BuildDiagnostics.command(forProjectKinds: ["Node project"], action: .test), "npm test")
        XCTAssertEqual(BuildDiagnostics.command(forProjectKinds: ["Rust crate"], action: .build), "cargo build")
    }

    /// Guessing a build command produces a failure that looks like a code problem.
    func testUnknownProjectReturnsNoCommand() {
        XCTAssertNil(BuildDiagnostics.command(forProjectKinds: [], action: .build))
    }

    /// An Xcode command is built from names on disk, so without a root there is nothing to build it from.
    func testXcodeProjectWithoutARootReturnsNoCommand() {
        XCTAssertNil(BuildDiagnostics.command(forProjectKinds: ["Xcode project"], action: .build))
    }

    func testSwiftPackageWinsWhenSeveralMarkersExist() {
        let kinds = ["Swift package", "Make-based build"]
        XCTAssertEqual(BuildDiagnostics.command(forProjectKinds: kinds, action: .build), "swift build")
    }

    // MARK: - Xcode command selection

    /// Builds a throwaway container tree: `Name.xcodeproj` plus optional shared scheme files.
    private func makeXcodeRoot(
        container: String,
        schemes: [String] = [],
        extraProjects: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-xcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        for name in [container] + extraProjects {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        if !schemes.isEmpty {
            // Shared schemes live under the .xcodeproj even when a workspace wraps it.
            let owner = extraProjects.first ?? container
            let dir = root.appendingPathComponent(owner).appendingPathComponent("xcshareddata/xcschemes")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for scheme in schemes {
                try "<Scheme/>".write(
                    to: dir.appendingPathComponent("\(scheme).xcscheme"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        return root.path
    }

    func testXcodeProjectUsesItsSharedScheme() throws {
        let root = try makeXcodeRoot(container: "Demo.xcodeproj", schemes: ["Demo"])
        XCTAssertEqual(
            BuildDiagnostics.command(forProjectKinds: ["Xcode project"], action: .build, at: root),
            "xcodebuild -project Demo.xcodeproj -scheme Demo -quiet build"
        )
        XCTAssertEqual(
            BuildDiagnostics.command(forProjectKinds: ["Xcode project"], action: .test, at: root),
            "xcodebuild -project Demo.xcodeproj -scheme Demo test"
        )
    }

    /// A workspace shares its schemes from the projects it wraps, and takes precedence over them.
    func testXcodeWorkspaceWinsAndFindsSchemesInItsProjects() throws {
        let root = try makeXcodeRoot(
            container: "Demo.xcworkspace",
            schemes: ["DemoApp"],
            extraProjects: ["Demo.xcodeproj"]
        )
        XCTAssertEqual(
            BuildDiagnostics.xcodebuildCommand(at: root, action: .build),
            "xcodebuild -workspace Demo.xcworkspace -scheme DemoApp -quiet build"
        )
    }

    /// A scheme named after the container is the app; anything else is a helper target.
    func testSchemeMatchingTheContainerNameIsPreferred() throws {
        let root = try makeXcodeRoot(container: "Demo.xcodeproj", schemes: ["AAAHelper", "Demo"])
        XCTAssertEqual(
            BuildDiagnostics.xcodebuildCommand(at: root, action: .build),
            "xcodebuild -project Demo.xcodeproj -scheme Demo -quiet build"
        )
    }

    /// xcodebuild answers a wrong scheme by listing the real ones, so the guess is self-correcting.
    func testNoSharedSchemeFallsBackToTheContainerName() throws {
        let root = try makeXcodeRoot(container: "Demo.xcodeproj")
        XCTAssertEqual(
            BuildDiagnostics.xcodebuildCommand(at: root, action: .build),
            "xcodebuild -project Demo.xcodeproj -scheme Demo -quiet build"
        )
    }

    func testContainerNamesWithSpacesAreQuoted() throws {
        let root = try makeXcodeRoot(container: "My App.xcodeproj", schemes: ["My App"])
        XCTAssertEqual(
            BuildDiagnostics.xcodebuildCommand(at: root, action: .test),
            "xcodebuild -project 'My App.xcodeproj' -scheme 'My App' test"
        )
    }

    func testDirectoryWithoutAnXcodeContainerHasNoCommand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(BuildDiagnostics.xcodebuildCommand(at: root.path, action: .build))
    }

    /// A package that also ships a generated .xcodeproj should keep using the faster SwiftPM path.
    func testSwiftPackageStillWinsOverAnXcodeProject() throws {
        let root = try makeXcodeRoot(container: "Demo.xcodeproj", schemes: ["Demo"])
        XCTAssertEqual(
            BuildDiagnostics.command(forProjectKinds: ["Swift package", "Xcode project"], action: .build, at: root),
            "swift build"
        )
    }
}
