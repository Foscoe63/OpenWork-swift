import Foundation

/// The app's own source files, for the tests that read them.
///
/// Files are found by name rather than by path, because the modules under `Sources/` are still
/// being split out and a file's folder changes when it moves to another module. Every file name
/// under `Sources/` is unique; `url(_:)` stops the test if that ever changes.
enum SourceTree {
    /// `Sources/` at the repository root.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SwiftOpenWorkTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources")

    /// Every Swift file under `Sources/`.
    static var swiftFiles: [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects ?? []).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The file a path such as `Engine/Agents/AgentRunner.swift` names. Only its file name is used.
    static func url(_ path: String) -> URL {
        let name = (path as NSString).lastPathComponent
        let matches = swiftFiles.filter { $0.lastPathComponent == name }
        precondition(matches.count == 1, "expected exactly one \(name) under Sources/, found \(matches.count)")
        return matches[0]
    }

    static func read(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }
}
