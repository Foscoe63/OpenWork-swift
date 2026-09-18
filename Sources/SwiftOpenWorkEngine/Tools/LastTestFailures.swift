import Foundation

/// Remembers which tests failed last, per workspace, so the next run can be narrowed to them.
///
/// The tight loop when fixing a test is: run the suite, fix one thing, run *that test* again. Doing
/// the second step by hand means the model must reconstruct a runner-specific filter flag from
/// diagnostic text, which it gets wrong in ways that fail quietly — a filter matching nothing exits
/// zero and reads as a pass.
///
/// Deliberately in memory only. A remembered failure list that outlived the app would narrow a run
/// against a checkout that has since changed, and report green for tests that no longer exist.
public actor LastTestFailures {
    public static let shared = LastTestFailures()

    private var byWorkspace: [String: [BuildDiagnostics.FailedTest]] = [:]

    public func record(_ failures: [BuildDiagnostics.FailedTest], for workspacePath: String) {
        if failures.isEmpty {
            // A green run clears the list; otherwise "only failing" would keep re-running tests
            // that already pass and report success without exercising anything new.
            byWorkspace.removeValue(forKey: workspacePath)
        } else {
            byWorkspace[workspacePath] = failures
        }
    }

    public func failures(for workspacePath: String) -> [BuildDiagnostics.FailedTest] {
        byWorkspace[workspacePath] ?? []
    }

    public func clear() {
        byWorkspace.removeAll()
    }
}
