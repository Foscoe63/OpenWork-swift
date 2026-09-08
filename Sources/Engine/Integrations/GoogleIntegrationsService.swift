import Foundation

/// Keychain-backed Google credentials + lightweight Gmail / Calendar REST helpers.
public final class GoogleIntegrationsService: @unchecked Sendable {
    public static let shared = GoogleIntegrationsService()

    public enum Key {
        public static let clientId = "google_client_id"
        public static let clientSecret = "google_client_secret"
        public static let apiKey = "google_api_key"
        public static let accessToken = "google_access_token"
        public static let refreshToken = "google_refresh_token"
    }

    private init() {}

    // MARK: - Credentials

    public var clientId: String {
        get { KeychainManager.shared.getSecret(forKey: Key.clientId) ?? "" }
        set { KeychainManager.shared.saveSecret(newValue, forKey: Key.clientId) }
    }

    public var clientSecret: String {
        get { KeychainManager.shared.getSecret(forKey: Key.clientSecret) ?? "" }
        set { KeychainManager.shared.saveSecret(newValue, forKey: Key.clientSecret) }
    }

    public var apiKey: String {
        get { KeychainManager.shared.getSecret(forKey: Key.apiKey) ?? "" }
        set { KeychainManager.shared.saveSecret(newValue, forKey: Key.apiKey) }
    }

    public var accessToken: String {
        get { KeychainManager.shared.getSecret(forKey: Key.accessToken) ?? "" }
        set { KeychainManager.shared.saveSecret(newValue, forKey: Key.accessToken) }
    }

    public var refreshToken: String {
        get { KeychainManager.shared.getSecret(forKey: Key.refreshToken) ?? "" }
        set { KeychainManager.shared.saveSecret(newValue, forKey: Key.refreshToken) }
    }

    public var isConfigured: Bool {
        !clientId.isEmpty && (!apiKey.isEmpty || !accessToken.isEmpty || !clientSecret.isEmpty)
    }

    public var hasOAuthToken: Bool {
        !accessToken.isEmpty
    }

    // MARK: - Gmail

    public func listGmailMessages(query: String = "is:unread newer_than:1d", maxResults: Int = 10) async -> String {
        guard hasOAuthToken else {
            return missingTokenMessage(service: "Gmail")
        }
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 25))))
        ]
        guard let listURL = components.url else {
            return "Error: invalid Gmail list URL"
        }

        do {
            let listJSON = try await authorizedGET(listURL)
            guard let messages = listJSON["messages"] as? [[String: Any]], !messages.isEmpty else {
                return "No Gmail messages matched query: `\(query)`"
            }

            var lines: [String] = ["### Gmail (\(messages.count) message\(messages.count == 1 ? "" : "s")) — query: `\(query)`\n"]
            for (idx, msg) in messages.prefix(maxResults).enumerated() {
                guard let id = msg["id"] as? String else { continue }
                let detailURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date")!
                let detail = try await authorizedGET(detailURL)
                let snippet = detail["snippet"] as? String ?? ""
                let headers = ((detail["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
                func header(_ name: String) -> String {
                    headers.first(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() })?["value"] as? String ?? ""
                }
                lines.append("\(idx + 1). **\(header("Subject").isEmpty ? "(no subject)" : header("Subject"))**")
                lines.append("   From: \(header("From"))")
                lines.append("   Date: \(header("Date"))")
                if !snippet.isEmpty {
                    lines.append("   \(snippet)")
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Gmail error: \(error.localizedDescription)"
        }
    }

    // MARK: - Google Calendar

    public func listCalendarEvents(daysAhead: Int = 7, maxResults: Int = 15) async -> String {
        guard hasOAuthToken else {
            return missingTokenMessage(service: "Google Calendar")
        }

        let calendar = Calendar.current
        let now = Date()
        let end = calendar.date(byAdding: .day, value: max(1, daysAhead), to: now) ?? now
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: iso.string(from: now)),
            URLQueryItem(name: "timeMax", value: iso.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 50))))
        ]
        guard let url = components.url else {
            return "Error: invalid Calendar URL"
        }

        do {
            let json = try await authorizedGET(url)
            guard let items = json["items"] as? [[String: Any]], !items.isEmpty else {
                return "No upcoming Google Calendar events in the next \(daysAhead) day(s)."
            }

            var lines: [String] = ["### Google Calendar — next \(daysAhead) day(s)\n"]
            for (idx, event) in items.enumerated() {
                let summary = event["summary"] as? String ?? "(untitled)"
                let start = event["start"] as? [String: Any]
                let when = start?["dateTime"] as? String ?? start?["date"] as? String ?? "unknown time"
                let location = event["location"] as? String ?? ""
                lines.append("\(idx + 1). **\(summary)**")
                lines.append("   When: \(when)")
                if !location.isEmpty {
                    lines.append("   Where: \(location)")
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Google Calendar error: \(error.localizedDescription)"
        }
    }

    public func testConnection() async -> String {
        if !isConfigured {
            return "Google is not configured. Add Client ID and API Key (and an OAuth Access Token for Gmail/Calendar) in Settings → Extensions."
        }
        if !hasOAuthToken {
            return "Client ID/API Key saved, but Gmail & Calendar need an OAuth Access Token. Paste a token from Google OAuth Playground (scopes: gmail.readonly, calendar.readonly)."
        }
        do {
            let url = URL(string: "https://www.googleapis.com/oauth2/v1/userinfo")!
            let json = try await authorizedGET(url)
            let email = json["email"] as? String ?? "unknown"
            let name = json["name"] as? String ?? ""
            return "✅ Connected to Google as \(name.isEmpty ? email : "\(name) <\(email)>")"
        } catch {
            return "Connection failed: \(error.localizedDescription). Check that the Access Token is valid and not expired."
        }
    }

    // MARK: - HTTP

    private func authorizedGET(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GoogleIntegrations",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(body.prefix(300))"]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GoogleIntegrations", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
        }
        return json
    }

    private func missingTokenMessage(service: String) -> String {
        """
        \(service) requires a Google OAuth Access Token.

        In Settings → Extensions → Google Integrations:
        1. Enter your Google Client ID and API Key (and Client Secret if you have one).
        2. Paste an OAuth Access Token with scopes:
           - `https://www.googleapis.com/auth/gmail.readonly`
           - `https://www.googleapis.com/auth/calendar.readonly`
        You can create a token via Google OAuth 2.0 Playground for testing.
        """
    }
}
