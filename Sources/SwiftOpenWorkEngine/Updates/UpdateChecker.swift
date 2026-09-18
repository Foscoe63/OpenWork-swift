import Foundation
import SwiftOpenWorkCore

/// Asks the GitHub releases page this app is actually published on whether a newer version exists.
///
/// The Updates page used to carry a disabled button and a disabled switch, because there was no
/// feed to ask. There is one — the releases are on GitHub — so the check is real now, and it is
/// read-only: it reports and links, it never downloads or installs anything.
///
/// Two rules worth keeping:
/// 1. **An unreadable answer is not "up to date".** A network failure, a rate limit or a tag that
///    is not a version all come back as `.failed`, and the UI says so. Claiming "you are on the
///    latest version" without having verified it is the fabrication this replaced.
/// 2. **Automatic checks are throttled to once a day** and skipped outside a real app bundle, so
///    tests and `swift run` never touch the network.
public enum UpdateChecker {

    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/Foscoe63/OpenWork-swift/releases/latest")!
    public static let automaticInterval: TimeInterval = 24 * 60 * 60
    public static let lastCheckKey = "SwiftOpenWork.updates.lastAutomaticCheck"

    public enum Outcome: Equatable {
        case upToDate(current: String)
        case available(current: String, latest: String, url: URL)
        case failed(reason: String)
    }

    /// Dotted numeric version, compared component-wise. "1.10.0" is newer than "1.9.3".
    public struct Version: Comparable, CustomStringConvertible {
        public let components: [Int]

        /// Accepts "1.2.3" and "v1.2.3". Anything else — "SWIFTOPENWORK", "1.2-beta" — is nil
        /// rather than a guess, because a guessed version is how a check reports the wrong answer.
        public init?(_ raw: String) {
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 4 else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
                numbers.append(n)
            }
            components = numbers
        }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for i in 0..<count {
                let l = i < lhs.components.count ? lhs.components[i] : 0
                let r = i < rhs.components.count ? rhs.components[i] : 0
                if l != r { return l < r }
            }
            return false
        }

        public static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

        public var description: String { components.map(String.init).joined(separator: ".") }
    }

    public static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Decides from a release payload. Pure, so the rules are testable without a network.
    public static func evaluate(releaseJSON: Data, currentVersion: String?) -> Outcome {
        guard let raw = currentVersion, let current = Version(raw) else {
            return .failed(reason: "This build does not report a version, so there is nothing to compare against.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: releaseJSON) as? [String: Any] else {
            return .failed(reason: "The release feed did not return readable data.")
        }
        guard let tag = object["tag_name"] as? String else {
            let message = (object["message"] as? String) ?? "no release tag in the response"
            return .failed(reason: "The release feed did not answer: \(message).")
        }
        guard let latest = Version(tag) else {
            return .failed(reason: "The latest release is tagged \"\(tag)\", which is not a version number.")
        }
        if current < latest {
            let page = (object["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/Foscoe63/OpenWork-swift/releases/latest")!
            return .available(current: current.description, latest: latest.description, url: page)
        }
        return .upToDate(current: current.description)
    }

    public static func check(session: URLSession = .shared) async -> Outcome {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return .failed(reason: "No published release was found.")
            }
            return evaluate(releaseJSON: data, currentVersion: currentVersion)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Whether a launch-time check is due. Pure for the same reason as `evaluate`.
    public static func automaticCheckIsDue(enabled: Bool, lastCheck: Date?, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= automaticInterval
    }

    /// Called at launch. Speaks only when there is something to act on — a silent success is the
    /// right amount of noise for a check nobody asked for this minute. A failure is not toasted at
    /// someone who is offline, and is not stamped, so the next launch tries again.
    @MainActor
    public static func runAutomaticCheckIfDue(appState: any EngineHost) {
        guard Bundle.main.bundleIdentifier != nil, !AppIdentity.isHostedByTests else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastCheckKey) as? Date
        guard automaticCheckIsDue(enabled: appState.settings.autoCheckForUpdates, lastCheck: last) else { return }
        Task { @MainActor in
            let outcome = await check()
            if case .failed = outcome { return }
            defaults.set(Date(), forKey: lastCheckKey)
            if case let .available(_, latest, _) = outcome {
                appState.showToast("SwiftOpenWork \(latest) is available — see Settings › Updates.")
            }
        }
    }
}
