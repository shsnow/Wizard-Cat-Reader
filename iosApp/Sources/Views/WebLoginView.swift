import SwiftUI
import WebKit

/// A visible browser for a source's site. Solving a Cloudflare verification or
/// signing in there leaves cookies, and this sheet hands them to the source's
/// HTTP client after every page load, so the source's requests start working.
struct WebLoginSheet: View {
    let sourceId: Int64
    let displayName: String
    let installed: InstalledExtension
    /// Opens here instead of the source's home page (a series' own page).
    var startURL: URL? = nil
    /// Called on close when cookies were handed to the engine at least once.
    var onFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WebLoginModel()
    @State private var info: JVMEngine.WebLoginInfo?
    @State private var loadError: String?
    @State private var pushedCookies = false

    var body: some View {
        NavigationStack {
            Group {
                if info != nil {
                    WebLoginPage(model: model)
                } else if let loadError {
                    EmptyStateView(
                        symbol: "exclamationmark.triangle",
                        title: "No se pudo abrir el sitio",
                        message: loadError
                    )
                } else {
                    ProgressView("Abriendo el sitio…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(model.title.isEmpty ? displayName : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cerrar")
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            model.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Recargar")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { close() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if info != nil {
                    Text("Resuelve la verificación o inicia sesión; las cookies se aplican a la fuente solas.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
            }
            // The callback holds the sheet, which holds the model: cleared here so a
            // dismissed sheet does not leak its WKWebView. Swiping the sheet away skips
            // close(), so the finished hook also fires from here.
            .onDisappear {
                model.onPageFinished = nil
                if pushedCookies { onFinished?() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let info = try await JVMEngine.shared.webLoginInfo(
                sourceId: sourceId, installed: installed
            )
            let base = info.baseURL == "null" ? "" : info.baseURL
            guard let target = startURL ?? URL(string: base), target.scheme != nil else {
                loadError = NSLocalizedString("La fuente no tiene un sitio web.", comment: "")
                return
            }
            self.info = info
            model.onPageFinished = { Task { await pushCookies() } }
            // The page navigates with the WebView's own Safari agent, never the
            // engine's: Cloudflare's checker loops forever on a WebKit view that
            // claims to be desktop Chrome. The agent that solved the challenge
            // travels to the engine with the cookies, so they stay valid there.
            model.start(url: target)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Dismisses right away; the hand-over to the (possibly busy) engine finishes in the
    /// background. Everything it needs is snapshotted first: after dismissal the sheet's
    /// state storage is gone.
    private func close() {
        Task {
            guard let info else {
                dismiss()
                return
            }
            var hosts: [String] = []
            for candidate in [URL(string: info.baseURL)?.host, startURL?.host, model.webView.url?.host] {
                if let candidate, !hosts.contains(candidate) { hosts.append(candidate) }
            }
            let lines = await model.harvestCookies(for: hosts)
            let agent = model.effectiveUserAgent
            // When true, onDisappear already notifies; this task then stays quiet.
            let alreadyPushed = pushedCookies
            let finished = onFinished
            dismiss()
            guard !lines.isEmpty, !alreadyPushed else { return }
            do {
                try await JVMEngine.shared.setWebLoginCookies(
                    lines, sourceId: sourceId, installed: installed, userAgent: agent
                )
                finished?()
            } catch {
                // Best effort: the per-page pushes may already have landed earlier.
            }
        }
    }

    /// Best effort: runs after every page load and again on close, so swiping
    /// the sheet away still keeps what the visit produced.
    private func pushCookies() async {
        guard let info else { return }
        var hosts: [String] = []
        for candidate in [URL(string: info.baseURL)?.host, startURL?.host, model.webView.url?.host] {
            if let candidate, !hosts.contains(candidate) { hosts.append(candidate) }
        }
        let lines = await model.harvestCookies(for: hosts)
        guard !lines.isEmpty else { return }
        do {
            try await JVMEngine.shared.setWebLoginCookies(
                lines,
                sourceId: sourceId,
                installed: installed,
                userAgent: model.effectiveUserAgent
            )
            pushedCookies = true
        } catch {
            // The next page load retries; a failed hand-over never blocks browsing.
        }
    }
}

private struct WebLoginPage: UIViewRepresentable {
    @ObservedObject var model: WebLoginModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Drives the sheet's WKWebView. It uses the shared default data store, so a
/// solved challenge persists across visits to the same site.
@MainActor
final class WebLoginModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var title = ""
    @Published var isLoading = false

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // A full Safari signature. The bare WKWebView agent has no Safari token
        // and some checkers treat it as an in-app bot.
        configuration.applicationNameForUserAgent = "Version/17.4 Mobile/15E148 Safari/604.1"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }()

    private var defaultUserAgent: String?
    private var startRequest: URLRequest?
    var onPageFinished: (() -> Void)?

    /// The agent the pages actually navigated with; the harvested cookies only
    /// count for requests that send this same agent, so it travels with them.
    var effectiveUserAgent: String? { defaultUserAgent }

    func start(url: URL) {
        guard startRequest == nil else { return }
        // Captured before the first page, so closing early still has the agent.
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            if let agent = value as? String, self?.defaultUserAgent == nil {
                self?.defaultUserAgent = agent
            }
        }
        let request = URLRequest(url: url)
        startRequest = request
        webView.load(request)
    }

    func reload() {
        if webView.url == nil, let startRequest {
            // The first load failed outright (offline): re-issue it instead.
            webView.load(startRequest)
            return
        }
        webView.reload()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        title = webView.title ?? ""
        if defaultUserAgent == nil {
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
                self?.defaultUserAgent = value as? String
                self?.onPageFinished?()
            }
        } else {
            onPageFinished?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
    }

    /// The visit's cookies for the given hosts, in the extension host's
    /// web-login format (one cookie per line, fields tab-separated).
    func harvestCookies(for hosts: [String]) async -> String {
        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        return cookies
            .filter { cookie in
                hosts.contains { Self.matches(host: $0, cookieDomain: cookie.domain) }
            }
            .map(Self.encode)
            .joined(separator: "\n")
    }

    private static func matches(host: String, cookieDomain: String) -> Bool {
        let domain = cookieDomain.hasPrefix(".")
            ? String(cookieDomain.dropFirst())
            : cookieDomain
        return host == domain || host.hasSuffix("." + domain)
    }

    /// name, value, domain and path percent-encoded (the host URL-decodes them),
    /// then expiresAtMs, secure, httpOnly and hostOnly.
    private static func encode(_ cookie: HTTPCookie) -> String {
        func field(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        // OkHttp's far-future MAX_DATE keeps session cookies alive for the client.
        let expires = cookie.expiresDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            ?? 253_402_300_799_999
        let hostOnly = !cookie.domain.hasPrefix(".")
        return [
            field(cookie.name),
            field(cookie.value),
            field(cookie.domain),
            field(cookie.path),
            String(expires),
            String(cookie.isSecure),
            String(cookie.isHTTPOnly),
            String(hostOnly),
        ].joined(separator: "\t")
    }
}
