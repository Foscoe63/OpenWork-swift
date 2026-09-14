import Foundation
import AppKit
import CryptoKit
import Network
import Security

/// Keychain-backed Google credentials + OAuth (browser sign-in) + Gmail / Calendar REST helpers.
public final class GoogleIntegrationsService: @unchecked Sendable {
    public static let shared = GoogleIntegrationsService()

    public enum Key {
        public static let clientId = "google_client_id"
        public static let clientSecret = "google_client_secret"
        public static let apiKey = "google_api_key"
        public static let accessToken = "google_access_token"
        public static let refreshToken = "google_refresh_token"
    }

    private enum DefaultsKey {
        static let tokenExpiresAt = "google_token_expires_at"
        static let accountEmail = "google_oauth_account_email"
        static let accountName = "google_oauth_account_name"
    }

    public static let oauthScopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly"
    ].joined(separator: " ")

    /// Stable loopback callback — must be listed under Authorized redirect URIs in Google Cloud Console
    /// (or use an OAuth client of type "Desktop app").
    public static let loopbackPort: UInt16 = 53682
    public static let authorizedRedirectURI = "http://127.0.0.1:\(loopbackPort)/"

    private let lock = NSLock()
    private var refreshTask: Task<Void, Error>?

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

    public var tokenExpiresAt: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: DefaultsKey.tokenExpiresAt)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: DefaultsKey.tokenExpiresAt)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.tokenExpiresAt)
            }
        }
    }

    public var signedInEmail: String {
        get { UserDefaults.standard.string(forKey: DefaultsKey.accountEmail) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.accountEmail) }
    }

    public var signedInName: String {
        get { UserDefaults.standard.string(forKey: DefaultsKey.accountName) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.accountName) }
    }

    public var isConfigured: Bool {
        !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasOAuthToken: Bool {
        !accessToken.isEmpty || !refreshToken.isEmpty
    }

    public var isSignedIn: Bool {
        !accessToken.isEmpty || !refreshToken.isEmpty
    }

    // MARK: - OAuth Sign-In / Sign-Out

    /// Opens the system browser for Google consent, receives the code on a local loopback port, and stores tokens.
    @MainActor
    public func signInWithGoogle() async throws -> String {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else {
            throw GoogleOAuthError.missingClientId
        }

        let pkce = PKCE.generate()
        let receiver = GoogleOAuthLoopbackReceiver()
        try await receiver.start(port: Self.loopbackPort)
        let redirectURI = Self.authorizedRedirectURI

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.oauthScopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]

        guard let authURL = components.url else {
            await receiver.stop()
            throw GoogleOAuthError.invalidAuthURL
        }

        let opened = NSWorkspace.shared.open(authURL)
        guard opened else {
            await receiver.stop()
            throw GoogleOAuthError.couldNotOpenBrowser
        }

        let callback: GoogleOAuthLoopbackReceiver.Callback
        do {
            callback = try await receiver.waitForCallback(timeout: 300)
        } catch {
            await receiver.stop()
            throw error
        }
        await receiver.stop()

        guard callback.state == pkce.state else {
            throw GoogleOAuthError.stateMismatch
        }
        if let error = callback.error {
            throw GoogleOAuthError.authorizationDenied(error)
        }
        guard let code = callback.code, !code.isEmpty else {
            throw GoogleOAuthError.missingAuthorizationCode
        }

        try await exchangeAuthorizationCode(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: pkce.verifier
        )

        let profile = try await fetchUserInfo()
        signedInEmail = profile.email
        signedInName = profile.name
        if !profile.email.isEmpty {
            var settings = PersistenceManager.shared.loadSettings()
            settings.googleAccountEmail = profile.email
            PersistenceManager.shared.saveSettings(settings)
        }

        let display = profile.name.isEmpty ? profile.email : "\(profile.name) <\(profile.email)>"
        return "✅ Signed in as \(display.isEmpty ? "Google account" : display)"
    }

    public func signOut() {
        accessToken = ""
        refreshToken = ""
        tokenExpiresAt = nil
        signedInEmail = ""
        signedInName = ""
    }

    // MARK: - Token refresh

    public func ensureValidAccessToken(forceRefresh: Bool = false) async throws {
        if !forceRefresh,
           !accessToken.isEmpty,
           let expires = tokenExpiresAt,
           expires.timeIntervalSinceNow > 60 {
            return
        }

        if !refreshToken.isEmpty {
            try await refreshAccessToken()
            return
        }

        if accessToken.isEmpty {
            throw GoogleOAuthError.notSignedIn
        }
    }

    private func refreshAccessToken() async throws {
        // Coalesce concurrent callers onto a single in-flight refresh. The check-and-create must
        // happen inside one lock acquisition to stay atomic; creating a Task itself doesn't
        // suspend, so this closure never awaits while holding the lock.
        let (taskToAwait, startedNewRefresh): (Task<Void, Error>, Bool) = lock.withLock {
            if let existing = refreshTask {
                return (existing, false)
            }
            let task = Task {
                try await self.performRefreshAccessToken()
            }
            refreshTask = task
            return (task, true)
        }

        defer {
            if startedNewRefresh {
                lock.withLock { refreshTask = nil }
            }
        }
        try await taskToAwait.value
    }

    private func performRefreshAccessToken() async throws {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else { throw GoogleOAuthError.missingClientId }
        guard !refreshToken.isEmpty else { throw GoogleOAuthError.notSignedIn }

        var body: [String: String] = [
            "client_id": trimmedClientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            body["client_secret"] = secret
        }

        let json = try await postForm(url: URL(string: "https://oauth2.googleapis.com/token")!, fields: body)
        guard let newAccess = json["access_token"] as? String, !newAccess.isEmpty else {
            throw GoogleOAuthError.tokenExchangeFailed("No access_token in refresh response")
        }
        accessToken = newAccess
        if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
            refreshToken = newRefresh
        }
        let expiresIn = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        tokenExpiresAt = Date().addingTimeInterval(expiresIn)
    }

    private func exchangeAuthorizationCode(code: String, redirectURI: String, codeVerifier: String) async throws {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: String] = [
            "client_id": trimmedClientId,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            body["client_secret"] = secret
        }

        let json = try await postForm(url: URL(string: "https://oauth2.googleapis.com/token")!, fields: body)
        guard let newAccess = json["access_token"] as? String, !newAccess.isEmpty else {
            let err = json["error_description"] as? String ?? json["error"] as? String ?? "unknown"
            throw GoogleOAuthError.tokenExchangeFailed(err)
        }
        accessToken = newAccess
        if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
            refreshToken = newRefresh
        }
        let expiresIn = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        tokenExpiresAt = Date().addingTimeInterval(expiresIn)
    }

    // MARK: - Gmail

    public func listGmailMessages(query: String = "is:unread newer_than:1d", maxResults: Int = 10) async -> String {
        do {
            try await ensureValidAccessToken()
        } catch {
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
        do {
            try await ensureValidAccessToken()
        } catch {
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
            return "Add your Google Client ID (and Client Secret for Desktop OAuth), then click Sign in with Google."
        }
        if !hasOAuthToken {
            return "Not signed in. Click Sign in with Google to authorize Gmail and Calendar access."
        }
        do {
            try await ensureValidAccessToken()
            let profile = try await fetchUserInfo()
            signedInEmail = profile.email
            signedInName = profile.name
            let display = profile.name.isEmpty ? profile.email : "\(profile.name) <\(profile.email)>"
            return "✅ Connected to Google as \(display.isEmpty ? "Google account" : display)"
        } catch {
            return "Connection failed: \(error.localizedDescription)"
        }
    }

    // MARK: - HTTP

    private func fetchUserInfo() async throws -> (email: String, name: String) {
        let json = try await authorizedGET(URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        return (
            email: json["email"] as? String ?? "",
            name: json["name"] as? String ?? ""
        )
    }

    private func authorizedGET(_ url: URL) async throws -> [String: Any] {
        try await ensureValidAccessToken()
        do {
            return try await performAuthorizedGET(url)
        } catch let error as NSError where error.domain == "GoogleIntegrations" && error.code == 401 {
            try await ensureValidAccessToken(forceRefresh: true)
            return try await performAuthorizedGET(url)
        }
    }

    private func performAuthorizedGET(_ url: URL) async throws -> [String: Any] {
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

    private func postForm(url: URL, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = fields
            .map { key, value in
                "\(Self.formEncode(key))=\(Self.formEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleOAuthError.tokenExchangeFailed("Invalid token response")
        }
        guard (200...299).contains(status) else {
            let err = json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)"
            throw GoogleOAuthError.tokenExchangeFailed(err)
        }
        return json
    }

    private static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func missingTokenMessage(service: String) -> String {
        """
        \(service) requires Google sign-in.

        In Settings → Extensions → Google Integrations:
        1. Enter your Google OAuth Client ID (Desktop app) and Client Secret.
        2. Click Sign in with Google and approve Gmail + Calendar access.
        """
    }
}

// MARK: - Errors

public enum GoogleOAuthError: LocalizedError {
    case missingClientId
    case invalidAuthURL
    case couldNotOpenBrowser
    case stateMismatch
    case authorizationDenied(String)
    case missingAuthorizationCode
    case notSignedIn
    case tokenExchangeFailed(String)
    case timeout
    case loopbackFailed(String)
    case redirectURIMismatch

    public var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "Enter your Google OAuth Client ID first."
        case .invalidAuthURL:
            return "Could not build the Google authorization URL."
        case .couldNotOpenBrowser:
            return "Could not open the system browser for Google sign-in."
        case .stateMismatch:
            return "OAuth state mismatch. Please try signing in again."
        case .authorizationDenied(let message):
            if message.localizedCaseInsensitiveContains("redirect_uri") {
                return GoogleOAuthError.redirectURIMismatch.errorDescription
            }
            return "Google authorization denied: \(message)"
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .notSignedIn:
            return "Not signed in to Google. Click Sign in with Google."
        case .tokenExchangeFailed(let message):
            if message.localizedCaseInsensitiveContains("redirect_uri") {
                return GoogleOAuthError.redirectURIMismatch.errorDescription
            }
            return "Token exchange failed: \(message)"
        case .timeout:
            return "Timed out waiting for Google sign-in. Try again."
        case .loopbackFailed(let message):
            return "Could not start local OAuth callback server: \(message)"
        case .redirectURIMismatch:
            return """
            redirect_uri_mismatch: In Google Cloud Console → Credentials → your OAuth client, add this Authorized redirect URI exactly:
            \(GoogleIntegrationsService.authorizedRedirectURI)
            Prefer an OAuth client of type “Desktop app”. If you use “Web application”, the redirect URI above is required.
            """
        }
    }
}

// MARK: - PKCE

private enum PKCE {
    struct Values {
        let verifier: String
        let challenge: String
        let state: String
    }

    static func generate() -> Values {
        let verifier = randomURLSafe(length: 64)
        let challenge = sha256Base64URL(verifier)
        let state = randomURLSafe(length: 32)
        return Values(verifier: verifier, challenge: challenge, state: state)
    }

    private static func randomURLSafe(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Base64URL(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback OAuth receiver

private actor GoogleOAuthLoopbackReceiver {
    struct Callback {
        var code: String?
        var state: String?
        var error: String?
    }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<Callback, Error>?

    func start(port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw GoogleOAuthError.loopbackFailed("Invalid port \(port)")
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw GoogleOAuthError.loopbackFailed("Port \(port) unavailable. Close anything using it, then try again. (\(error.localizedDescription))")
        }
        self.listener = listener

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class ResumeOnce: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                let cont: CheckedContinuation<Void, Error>
                init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }
                func resume(returning: Void = ()) {
                    lock.lock(); defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    cont.resume()
                }
                func resume(throwing error: Error) {
                    lock.lock(); defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: error)
                }
            }
            let once = ResumeOnce(cont)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume()
                case .failed(let error):
                    once.resume(throwing: GoogleOAuthError.loopbackFailed(error.localizedDescription))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                Task { await self.handle(connection: connection) }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fireTimeout()
            }
        }
    }

    private func fireTimeout() {
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume(throwing: GoogleOAuthError.timeout)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let pending = continuation {
            continuation = nil
            pending.resume(throwing: CancellationError())
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            Task {
                guard let self else {
                    connection.cancel()
                    return
                }
                defer { connection.cancel() }

                if let error {
                    await self.fail(error)
                    return
                }
                guard let data, let request = String(data: data, encoding: .utf8) else {
                    await self.fail(GoogleOAuthError.loopbackFailed("Empty callback request"))
                    return
                }

                let callback = Self.parseCallback(from: request)
                let html = """
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>OpenWork</title></head>
                <body style="font-family:-apple-system,sans-serif;padding:40px;text-align:center">
                <h2>Google sign-in complete</h2>
                <p>You can close this window and return to OpenWork.</p>
                </body></html>
                """
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(html.utf8.count)\r
                Connection: close\r
                \r
                \(html)
                """
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })

                await self.finish(callback)
            }
        }
    }

    private func finish(_ callback: Callback) {
        if let pending = continuation {
            continuation = nil
            pending.resume(returning: callback)
        }
    }

    private func fail(_ error: Error) {
        if let pending = continuation {
            continuation = nil
            pending.resume(throwing: error)
        }
    }

    private static func parseCallback(from request: String) -> Callback {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
        let pathPart = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let qIndex = pathPart.firstIndex(of: "?") else {
            return Callback(error: "missing_query")
        }
        let query = String(pathPart[pathPart.index(after: qIndex)...])
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            items[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return Callback(
            code: items["code"],
            state: items["state"],
            error: items["error"] ?? items["error_description"]
        )
    }
}
