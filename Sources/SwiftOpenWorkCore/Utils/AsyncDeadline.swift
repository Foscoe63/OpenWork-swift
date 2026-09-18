import Foundation

/// Stop waiting on work that cannot be cancelled.
///
/// The obvious way to time something out — race it against `Task.sleep` inside a
/// `withThrowingTaskGroup` — does not work when the work ignores cancellation. A task group waits
/// for every child before it returns, and cancelling a task suspended in a synchronous C call (or
/// any library that never checks `Task.isCancelled`) does not resume it. The timeout then blocks
/// on the very thing it was meant to abandon.
///
/// This gives up waiting without waiting for the work to stop. The work keeps running, which is
/// usually what you want: a model load that overruns its budget still finishes and populates its
/// cache for the next attempt.
public enum AsyncDeadline {

    public struct TimedOut: Error, LocalizedError {
        public let seconds: TimeInterval
        public var errorDescription: String? {
            "Timed out after \(Int(seconds))s."
        }
    }

    /// Resumes a continuation at most once, whichever racer gets there first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(throwing: error)
        }
    }

    /// Reports when something last made progress, so a watchdog can time silence rather than
    /// total duration.
    public final class ProgressClock: @unchecked Sendable {
        private let lock = NSLock()
        private var lastTick: Date

        public init() {
            lastTick = Date()
        }

        public func tick() {
            lock.lock()
            lastTick = Date()
            lock.unlock()
        }

        public var secondsSinceLastTick: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(lastTick)
        }
    }

    /// Await `task`, giving up only once it has made no progress for `stalledAfter` seconds.
    ///
    /// A fixed budget is the wrong shape for work whose duration depends on how much there is to
    /// do — loading a 46GB checkpoint, or downloading one. Timing the silence instead means work
    /// that is visibly moving is never abandoned, while work that is wedged still fails rather
    /// than hanging forever.
    ///
    /// As with `wait(for:seconds:)`, the task keeps running after this gives up.
    public static func wait<T: Sendable>(
        for task: Task<T, Error>,
        stalledAfter seconds: TimeInterval,
        clock: ProgressClock,
        pollInterval: TimeInterval = 5
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            Task {
                do {
                    once.resume(returning: try await task.value)
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task {
                while true {
                    let quiet = clock.secondsSinceLastTick
                    if quiet >= seconds {
                        once.resume(throwing: TimedOut(seconds: seconds))
                        return
                    }
                    // Sleep only as long as the remaining quiet allows, so the check does not
                    // overshoot the deadline by a whole poll interval.
                    let nap = min(pollInterval, max(0.25, seconds - quiet))
                    try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
                }
            }
        }
    }

    /// Await `task` for at most `seconds`, throwing `TimedOut` instead of blocking past it.
    ///
    /// The task is left running deliberately — the caller keeps its handle and can observe the
    /// result later.
    public static func wait<T: Sendable>(
        for task: Task<T, Error>,
        seconds: TimeInterval
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            Task {
                do {
                    once.resume(returning: try await task.value)
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(throwing: TimedOut(seconds: seconds))
            }
        }
    }
}
