import Foundation
import AppKit
import WebKit
import Combine

/// One preview tab: a web view that outlives the pane showing it, so switching inspector tabs does
/// not reload the app you are looking at or lose its state. `PreviewSessions` holds the tabs.
@MainActor
public final class PreviewController: NSObject, ObservableObject, Identifiable {

    public let id = UUID()
    /// The dev server this tab was opened for, when it was opened for one.
    @Published public var serverId: UUID?

    @Published public private(set) var currentURL: URL?
    @Published public private(set) var title: String = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var console: [PreviewConsoleEntry] = []
    @Published public private(set) var loadError: String?
    @Published public private(set) var httpStatus: Int?
    /// Width the page is laid out at; nil fills the pane.
    @Published public var viewportWidth: CGFloat?
    /// Reload when a workspace file is saved. Most dev servers hot-reload by themselves; plain
    /// files served by the app do not.
    @Published public var reloadOnSave = true

    /// The folder `file://` pages may load from.
    public var workspaceRoot: String?

    public static let maxConsoleEntries = 500

    private var webViewStorage: WKWebView?
    private var navigationWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastNavigationStart = Date()
    private var offscreenWindow: NSWindow?
    private var observations: [NSKeyValueObservation] = []
    private var fileWatcher: DirectoryChangeWatcher?

    public override init() {
        super.init()
    }

    public var webView: WKWebView {
        if let webViewStorage { return webViewStorage }
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: PreviewInstrumentation.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.add(WeakScriptMessageHandler(self), name: PreviewInstrumentation.messageHandlerName)
        configuration.userContentController = controller
        // A throwaway store: a preview must not share cookies with anything, and must not leave
        // logins from someone's half-built auth flow lying around.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        if #available(macOS 13.3, *) { view.isInspectable = true }
        view.allowsBackForwardNavigationGestures = true

        observations = [
            view.observe(\.canGoBack) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            view.observe(\.title) { [weak self] view, _ in
                Task { @MainActor in self?.title = view.title ?? "" }
            },
            view.observe(\.url) { [weak self] view, _ in
                Task { @MainActor in if let url = view.url { self?.currentURL = url } }
            },
        ]
        webViewStorage = view
        return view
    }

    // MARK: Navigation

    public func load(_ url: URL) {
        loadError = nil
        httpStatus = nil
        lastNavigationStart = Date()
        currentURL = url
        if url.isFileURL {
            let readAccess = workspaceRoot.map { URL(fileURLWithPath: $0) } ?? url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        } else {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        watchWorkspaceIfNeeded()
    }

    public func reload() {
        guard currentURL != nil else { return }
        loadError = nil
        lastNavigationStart = Date()
        if webView.url == nil, let currentURL {
            load(currentURL)
        } else {
            webView.reloadFromOrigin()
        }
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }

    public func clearConsole() { console.removeAll() }

    /// What the tab strip calls this preview: the page title, else host and port.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let url = currentURL else { return "New Preview" }
        if url.isFileURL { return url.lastPathComponent }
        return [url.host, url.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }

    /// Stop rendering and release the web view, for a closed tab.
    public func tearDown() {
        webViewStorage?.stopLoading()
        webViewStorage?.removeFromSuperview()
        webViewStorage?.configuration.userContentController.removeAllScriptMessageHandlers()
        webViewStorage = nil
        observations = []
        fileWatcher = nil
        offscreenWindow?.orderOut(nil)
        offscreenWindow?.contentView = nil
        offscreenWindow = nil
        resumeNavigationWaiters()
    }

    public var problemCount: Int { console.filter { $0.level.isProblem }.count }

    // MARK: Checking a page for the agent

    public struct CheckResult {
        public var url: String
        public var title: String
        public var httpStatus: Int?
        public var loadError: String?
        public var console: [PreviewConsoleEntry]
        public var visibleText: String?
        public var screenshotPath: String?
    }

    /// Load (or reload) the page, let it settle, and report what happened.
    ///
    /// Console output is taken from the start of this load only, so an error fixed since the
    /// last check is not reported again.
    public func check(
        url: URL?,
        reload: Bool,
        settleSeconds: Double,
        viewportWidth: CGFloat?,
        screenshotDirectory: URL?
    ) async -> CheckResult {
        ensureHostedForRendering()
        if let viewportWidth { self.viewportWidth = viewportWidth }

        let started = Date()
        if let url, url != currentURL || webView.url == nil {
            load(url)
        } else if reload || webView.url == nil {
            self.reload()
        }
        await waitForNavigation(timeout: 30)
        try? await Task.sleep(nanoseconds: UInt64(max(0, min(settleSeconds, 20)) * 1_000_000_000))

        let text = try? await webView.evaluateJavaScript(
            "document.body ? document.body.innerText.slice(0, 4000) : ''"
        ) as? String
        let pageTitle = (try? await webView.evaluateJavaScript("document.title") as? String) ?? title

        var screenshotPath: String?
        if let screenshotDirectory, loadError == nil {
            screenshotPath = await snapshot(to: screenshotDirectory)
        }
        return CheckResult(
            url: (webView.url ?? currentURL)?.absoluteString ?? "",
            title: pageTitle,
            httpStatus: httpStatus,
            loadError: loadError,
            console: console.filter { $0.timestamp >= started.addingTimeInterval(-0.05) },
            visibleText: loadError == nil ? text : nil,
            screenshotPath: screenshotPath
        )
    }

    private func waitForNavigation(timeout: TimeInterval) async {
        // Give WebKit a moment to report that loading began.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard isLoading || webView.isLoading else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    if !self.isLoading && !self.webView.isLoading {
                        continuation.resume()
                    } else {
                        self.navigationWaiters.append(continuation)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
        resumeNavigationWaiters()
    }

    private func resumeNavigationWaiters() {
        let waiters = navigationWaiters
        navigationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func snapshot(to directory: URL) async -> String? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let file = directory.appendingPathComponent("preview-\(formatter.string(from: Date())).png")
        do {
            try png.write(to: file)
            return file.path
        } catch {
            return nil
        }
    }

    /// WebKit only renders a view that is in a window. When the pane is not on screen — another
    /// inspector tab, or a run nobody is watching — the view is parked in an invisible window so a
    /// check still sees a real, laid-out page.
    private func ensureHostedForRendering() {
        let view = webView
        guard view.window == nil else { return }
        let width = viewportWidth ?? 1280
        let window = offscreenWindow ?? {
            let created = NSWindow(
                contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 900),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            created.isReleasedWhenClosed = false
            created.ignoresMouseEvents = true
            created.alphaValue = 0.01
            created.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            return created
        }()
        offscreenWindow = window
        window.setContentSize(NSSize(width: width, height: 900))
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        window.orderBack(nil)
    }

    /// Release the offscreen host once the pane has taken the view back.
    public func didAttachToPane() {
        guard let window = offscreenWindow else { return }
        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: Reload on save

    private func watchWorkspaceIfNeeded() {
        guard let root = workspaceRoot else { return }
        if fileWatcher?.root == root { return }
        fileWatcher = DirectoryChangeWatcher(root: root) { [weak self] paths in
            Task { @MainActor in
                guard let self, self.reloadOnSave, self.currentURL != nil else { return }
                guard paths.contains(where: DirectoryChangeWatcher.isRelevant) else { return }
                self.reload()
            }
        }
    }

    fileprivate func record(_ entry: PreviewConsoleEntry) {
        console.append(entry)
        if console.count > Self.maxConsoleEntries {
            console.removeFirst(console.count - Self.maxConsoleEntries)
        }
    }
}

// MARK: - WebKit delegates

extension PreviewController: WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if PreviewURLPolicy.loadsInPane(url, workspaceRoot: workspaceRoot) {
            decisionHandler(.allow)
        } else {
            // A link out of the app being built goes to the real browser.
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame?.isMainFrame == true {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            httpStatus = response.statusCode
            if response.statusCode >= 400 {
                record(PreviewConsoleEntry(
                    level: .network,
                    message: "\(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode)) \(response.url?.absoluteString ?? "")",
                    pageURL: response.url?.absoluteString ?? ""
                ))
            }
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadError = nil
    }

    /// A new page starts a new log, as a browser's console does without "Preserve log". Keeping
    /// the old entries made the error badge count errors that a reload had already fixed.
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let carried = console.filter { $0.timestamp >= lastNavigationStart && $0.level == .network }
        console = carried
        record(PreviewConsoleEntry(level: .info, message: "Loaded \(webView.url?.absoluteString ?? "page")", pageURL: webView.url?.absoluteString ?? ""))
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        resumeNavigationWaiters()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishWithError(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishWithError(error)
    }

    private func finishWithError(_ error: Error) {
        isLoading = false
        let nsError = error as NSError
        // A navigation replaced by another one is not a failure of the page.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            resumeNavigationWaiters()
            return
        }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { // frame load interrupted
            resumeNavigationWaiters()
            return
        }
        loadError = nsError.code == NSURLErrorCannotConnectToHost
            ? "Could not connect to \(currentURL?.host ?? "the server"):\(currentURL?.port.map(String.init) ?? "") — is the server running?"
            : nsError.localizedDescription
        record(PreviewConsoleEntry(level: .error, message: "Load failed: \(loadError ?? "")", pageURL: currentURL?.absoluteString ?? ""))
        resumeNavigationWaiters()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        record(PreviewConsoleEntry(level: .exception, message: "The page's web process crashed (often an infinite loop or runaway memory). Reloading.", pageURL: currentURL?.absoluteString ?? ""))
        webView.reload()
    }

    // `window.open` / target=_blank: keep loopback in the pane, send the rest to the browser.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if PreviewURLPolicy.loadsInPane(url, workspaceRoot: workspaceRoot) {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        // Recorded instead of shown: a modal alert would block an unattended check forever.
        record(PreviewConsoleEntry(level: .info, message: "alert(): \(message)", pageURL: frame.request.url?.absoluteString ?? ""))
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        record(PreviewConsoleEntry(level: .info, message: "confirm(): \(message) — answered OK", pageURL: frame.request.url?.absoluteString ?? ""))
        completionHandler(true)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let rawLevel = body["level"] as? String,
              let text = body["message"] as? String else { return }
        let level = PreviewConsoleEntry.Level(rawValue: rawLevel) ?? .log
        record(PreviewConsoleEntry(level: level, message: text, pageURL: body["url"] as? String ?? ""))
    }
}

/// `WKUserContentController` retains its handlers; this keeps it from retaining the controller.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// File-system events for a folder tree, for reload-on-save.
///
/// FSEvents rather than per-file watchers: editors and agents save by writing a temporary file and
/// renaming it over the original, which a watcher on the original inode never sees.
public final class DirectoryChangeWatcher {
    public let root: String
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    public init(root: String, handler: @escaping ([String]) -> Void) {
        self.root = root
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(Array(array.prefix(count)))
        }
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Changes worth a reload: source and assets, not dependency installs, VCS or build caches.
    public static func isRelevant(_ path: String) -> Bool {
        let ignored = ["/node_modules/", "/.git/", "/.swiftopenwork/", "/.next/", "/.nuxt/", "/.svelte-kit/",
                       "/.build/", "/DerivedData/", "/__pycache__/", "/.cache/", "/.turbo/", "/target/"]
        if ignored.contains(where: { path.contains($0) }) { return false }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") || name.hasSuffix("~") || name.hasSuffix(".swp") || name.hasSuffix(".tmp") { return false }
        return true
    }
}
