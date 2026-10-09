import AppKit
import Combine
import WebKit

/// The built-in floating browser: real web pages rendered directly inside the floating
/// window with WebKit (Safari's engine). Needs no Screen Recording or Accessibility
/// permission, and input, resizing and cursors are all native.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    /// Asks the address bar to take focus (⌘L, new tab).
    @Published var focusAddressBar = 0

    /// One configuration for every tab: shared cookies and logins, kept on disk.
    let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        return config
    }()

    /// Safari's user agent: some sites (e.g. Google sign-in) refuse unknown embedded browsers.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let homePage = URL(string: "https://www.google.com")!

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
    var isEmpty: Bool { tabs.isEmpty }

    // MARK: Tabs

    @discardableResult
    func newTab(_ url: URL? = nil, select: Bool = true, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration ?? self.configuration, owner: self)
        if let selected, let index = tabs.firstIndex(where: { $0.id == selected.id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select { selectedID = tab.id }
        if let url { tab.webView.load(URLRequest(url: url)) } else if configuration == nil { focusAddressBar += 1 }
        saveSession()
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.webView.stopLoading()
        tabs.remove(at: index)
        if selectedID == tab.id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        saveSession()
    }

    func select(_ tab: BrowserTab) { selectedID = tab.id }

    func selectNext(_ step: Int) {
        guard let current = selected, let index = tabs.firstIndex(where: { $0.id == current.id }), !tabs.isEmpty else { return }
        selectedID = tabs[(index + step + tabs.count) % tabs.count].id
    }

    /// Address bar input: a URL, a bare domain, or a search.
    func go(_ input: String) {
        guard let url = Self.url(from: input) else { return }
        if let tab = selected { tab.webView.load(URLRequest(url: url)) } else { newTab(url) }
    }

    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme) { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text) { return url }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    // MARK: Session (tabs survive relaunch)

    func restoreSession() {
        guard tabs.isEmpty else { return }
        let urls = Settings.browserTabs.compactMap(URL.init(string:))
        if urls.isEmpty { newTab(Self.homePage) } else { urls.forEach { newTab($0, select: false) } }
        selectedID = tabs.first?.id
    }

    func saveSession() {
        Settings.browserTabs = tabs.compactMap { $0.webView.url?.absoluteString ?? $0.pendingURL?.absoluteString }
    }
}

/// One tab: a WKWebView plus the state the toolbar shows.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let id = UUID()
    let webView: WKWebView
    @Published var title = "New Tab"
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    var pendingURL: URL?
    private weak var owner: BrowserModel?
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, owner: BrowserModel) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.owner = owner
        super.init()
        webView.customUserAgent = BrowserModel.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] web, _ in MainActor.assumeIsolated { self?.title = (web.title?.isEmpty == false ? web.title : nil) ?? web.url?.host() ?? "New Tab" } },
            webView.observe(\.url) { [weak self] web, _ in MainActor.assumeIsolated { self?.url = web.url; self?.owner?.saveSession() } },
            webView.observe(\.canGoBack) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoBack = web.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoForward = web.canGoForward } },
            webView.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { self?.isLoading = web.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] web, _ in MainActor.assumeIsolated { self?.progress = web.estimatedProgress } },
        ]
    }

    // MARK: WKUIDelegate

    /// target=_blank links and window.open() become new tabs.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let owner else { return nil }
        return owner.newTab(nil, select: true, configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Page"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // ⌘-click opens a link in a new tab.
        if navigationAction.modifierFlags.contains(.command), navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            owner?.newTab(url, select: false)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKDownloadDelegate: files go to ~/Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = downloads.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            destination = downloads.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        log("browser: downloading to \(destination.path)")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        log("browser: download finished")
    }
}
