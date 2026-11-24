import Foundation
import UIKit
import WebKit
import WizardJVMRunner

// The native side of app.tachiaz.compat.IOSWebViewProviderFactory: Android's
// WebView and CookieManager, as extensions use them, backed by real WKWebViews.
//
// Threads:
// - Commands arrive on JVM threads and hop to the main thread, where WebKit lives.
//   The JVM thread waits; the main thread never waits for Java.
// - Events leave the main thread for a background queue before calling into
//   Java, because some of them wait for Java's emulated main looper.

/// Entry point the JVM compat layer calls (resolved by name from WizardNatives.cpp).
@_cdecl("wizardcat_webkit_command")
func wizardWebKitCommand(
    _ operation: UnsafePointer<CChar>?,
    _ handle: Int64,
    _ argument1: UnsafePointer<CChar>?,
    _ argument2: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let name = operation.map { String(cString: $0) } ?? ""
    let first = argument1.map { String(cString: $0) }
    let second = argument2.map { String(cString: $0) }
    let result = WebKitBridge.command(name, handle: handle, first, second)
    return strdup(result)
}

/// Thread-agnostic plumbing: never touches WebKit directly.
enum WebKitBridge {
    /// Page events, in order (started before finished).
    static let events = DispatchQueue(label: "cl.jonas.wizardcat.webkit-events", qos: .userInitiated)
    /// Calls whose answer WebKit is waiting for (navigation policy, sync JS bridge).
    static let replies = DispatchQueue(
        label: "cl.jonas.wizardcat.webkit-replies", qos: .userInitiated, attributes: .concurrent
    )
    /// Longest a JVM thread waits for the main thread or for a script.
    static let timeout: TimeInterval = 30

    static func command(_ operation: String, handle: Int64, _ first: String?, _ second: String?) -> String {
        switch operation {
            case "evaluate":
                let script = first ?? ""
                return waitOnMain { done in
                    WebKitViews.evaluate(handle: handle, script: script, completion: done)
                } ?? "null"
            case "cookieGet", "cookieSet", "cookieRemoveSession", "cookieRemoveAll", "cookieHas", "cookieFlush":
                return waitOnMain { done in
                    WebKitCookies.run(operation, first, second, completion: done)
                } ?? ""
            default:
                return waitOnMain { done in
                    done(WebKitViews.perform(operation, handle: handle, first, second))
                } ?? ""
        }
    }

    /// Runs `body` on the main thread and blocks the calling (JVM) thread until it
    /// reports a value, or nil after `timeout`. Never called on the main thread.
    static func waitOnMain(
        _ body: @escaping @MainActor (_ done: @escaping (String) -> Void) -> Void
    ) -> String? {
        let box = ReplyBox()
        if Thread.isMainThread {
            // Not expected (Java never runs on the main thread); avoid deadlocking.
            Task { @MainActor in body { box.fulfil($0) } }
            return box.value
        }
        Task { @MainActor in body { box.fulfil($0) } }
        return box.wait(timeout: timeout)
    }

    /// Sends one event to Java. Call only off the main thread.
    static func send(_ handle: Int64, _ event: String, _ first: String? = nil, _ second: String? = nil) -> String? {
        WebKitEvents.dispatch(handle: handle, event: event, first, second)
    }

    // MARK: - Wire format (shared with IOSWebViewProviderFactory.java)

    static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    static func decode(_ value: String) -> String {
        guard let data = Data(base64Encoded: value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// "base64(name):base64(value)" per line.
    static func encodeHeaders(_ headers: [String: String]) -> String {
        headers.map { "\(encode($0.key)):\(encode($0.value))" }.joined(separator: "\n")
    }

    static func decodeHeaders(_ value: String?) -> [String: String] {
        guard let value, !value.isEmpty else { return [:] }
        var output: [String: String] = [:]
        for line in value.split(separator: "\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = decode(String(line[..<separator]))
            guard !name.isEmpty else { continue }
            output[name] = decode(String(line[line.index(after: separator)...]))
        }
        return output
    }

    /// url, method, isMainFrame, isRedirect, hasGesture, headers.
    static func encodeRequest(
        url: String,
        method: String,
        mainFrame: Bool,
        redirect: Bool,
        gesture: Bool,
        headers: [String: String]
    ) -> String {
        [
            encode(url),
            encode(method),
            String(mainFrame),
            String(redirect),
            String(gesture),
            encode(encodeHeaders(headers)),
        ].joined(separator: "\n")
    }

    /// JSON string literal for embedding `value` in JavaScript.
    static func javascriptLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }
}

/// One answer, handed from the main thread to a waiting JVM thread.
final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var stored: String?
    private var fulfilled = false

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func fulfil(_ value: String) {
        lock.lock()
        guard !fulfilled else {
            lock.unlock()
            return
        }
        fulfilled = true
        stored = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> String? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return value
    }
}

// MARK: - Views

/// The live WebViews, by the handle Java knows them by. Main thread only.
@MainActor
enum WebKitViews {
    private static var views: [Int64: BridgedWebView] = [:]
    private static var nextHandle: Int64 = 1

    static func perform(_ operation: String, handle: Int64, _ first: String?, _ second: String?) -> String {
        if operation == "create" {
            let created = nextHandle
            nextHandle += 1
            views[created] = BridgedWebView(handle: created)
            return String(created)
        }
        guard let view = views[handle] else { return "" }
        let webView = view.webView
        switch operation {
            case "destroy":
                view.tearDown()
                views[handle] = nil
            case "load":
                view.load(first ?? "", headers: WebKitBridge.decodeHeaders(second))
            case "post":
                view.post(first ?? "", body: Data(base64Encoded: second ?? "") ?? Data())
            case "loadHTML":
                view.loadHTML(baseURL: first, html: WebKitBridge.decode(second ?? ""))
            case "addJSInterface":
                view.addInterface(name: first ?? "", asyncMethods: second ?? "")
            case "removeJSInterface":
                view.removeInterface(name: first ?? "")
            case "userAgent":
                let agent = first ?? ""
                webView.customUserAgent = agent.isEmpty ? nil : agent
            case "settings":
                // javaScript, domStorage, ... : WebKit keeps JavaScript and storage on,
                // which is what every extension that opens a WebView asks for.
                break
            case "stop": webView.stopLoading()
            case "reload": view.reload()
            case "goBack": webView.goBack()
            case "goForward": webView.goForward()
            case "go":
                if let steps = Int(first ?? ""), let item = webView.backForwardList.item(at: steps) {
                    webView.go(to: item)
                }
            case "canGoBack": return String(webView.canGoBack)
            case "canGoForward": return String(webView.canGoForward)
            case "canGo":
                let steps = Int(first ?? "") ?? 0
                return String(webView.backForwardList.item(at: steps) != nil)
            case "url": return webView.url?.absoluteString ?? ""
            case "originalUrl":
                return webView.backForwardList.currentItem?.initialURL.absoluteString
                    ?? webView.url?.absoluteString ?? ""
            case "title": return webView.title ?? ""
            case "progress": return String(Int(webView.estimatedProgress * 100))
            case "contentHeight": return String(Int(webView.scrollView.contentSize.height))
            case "contentWidth": return String(Int(webView.scrollView.contentSize.width))
            case "clearCache":
                WKWebsiteDataStore.default().removeData(
                    ofTypes: [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache],
                    modifiedSince: .distantPast
                ) {}
            default:
                // clearHistory and the rest have no WKWebView equivalent.
                break
        }
        return ""
    }

    static func evaluate(handle: Int64, script: String, completion: @escaping (String) -> Void) {
        guard let view = views[handle] else {
            completion("null")
            return
        }
        view.evaluate(script, completion: completion)
    }
}

/// One Android WebView. Lives off screen, attached to the window so WebKit does
/// not throttle its timers.
@MainActor
final class BridgedWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let syncBridgePrompt = "__wizardcat_bridge__"
    static let messageHandlerName = "wizardBridge"

    let handle: Int64
    let webView: WKWebView
    /// Kept directly: WKWebView.configuration hands out copies.
    private let contentController: WKUserContentController
    private let messageProxy: BridgeMessageProxy
    /// Interface name → its void methods (name → argument count).
    private var interfaces: [String: [String: Int]] = [:]
    /// Android does not ask shouldOverrideUrlLoading about loadUrl() itself.
    private var programmaticLoadPending = false

    init(handle: Int64) {
        let proxy = BridgeMessageProxy()
        let controller = WKUserContentController()
        controller.add(proxy, name: BridgedWebView.messageHandlerName)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/17.4 Mobile/15E148 Safari/604.1"
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController = controller
        self.handle = handle
        self.messageProxy = proxy
        self.contentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        proxy.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        Self.hostWindow()?.insertSubview(webView, at: 0)
        controller.addUserScript(Self.requestObserver)
    }

    private static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        contentController.removeAllUserScripts()
        contentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.removeFromSuperview()
        messageProxy.owner = nil
    }

    // MARK: Loading

    func load(_ address: String, headers: [String: String]) {
        guard let url = URL(string: address) else { return }
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        programmaticLoadPending = true
        webView.load(request)
    }

    func post(_ address: String, body: Data) {
        guard let url = URL(string: address) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        programmaticLoadPending = true
        webView.load(request)
    }

    func loadHTML(baseURL: String?, html: String) {
        programmaticLoadPending = true
        webView.loadHTMLString(html, baseURL: baseURL.flatMap { URL(string: $0) })
    }

    func reload() {
        programmaticLoadPending = true
        webView.reload()
    }

    /// Android's evaluateJavascript: the script's completion value as JSON, at the
    /// page's global scope (multi-line scripts included).
    func evaluate(_ script: String, completion: @escaping (String) -> Void) {
        let wrapped = """
        (function(){try{var __wcR=(0,eval)(\(WebKitBridge.javascriptLiteral(script)));\
        if(__wcR===undefined)return 'null';var __wcS=JSON.stringify(__wcR);\
        return __wcS===undefined?'null':__wcS;}catch(__wcE){return 'null';}})()
        """
        webView.evaluateJavaScript(wrapped) { value, _ in
            completion((value as? String) ?? "null")
        }
    }

    // MARK: JavaScript interfaces

    func addInterface(name: String, asyncMethods: String) {
        guard !name.isEmpty else { return }
        var methods: [String: Int] = [:]
        for line in asyncMethods.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if let method = parts.first {
                methods[String(method)] = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            }
        }
        interfaces[name] = methods
        installInterfaceScripts()
        // Pages already on screen get it now; later ones at document start.
        webView.evaluateJavaScript(
            Self.interfaceScript(name: name, asyncMethods: methods), completionHandler: nil
        )
    }

    func removeInterface(name: String) {
        interfaces[name] = nil
        installInterfaceScripts()
        webView.evaluateJavaScript(
            "try{delete window[\(WebKitBridge.javascriptLiteral(name))]}catch(e){}",
            completionHandler: nil
        )
    }

    private func installInterfaceScripts() {
        let controller = contentController
        controller.removeAllUserScripts()
        controller.addUserScript(Self.requestObserver)
        for (name, methods) in interfaces {
            controller.addUserScript(WKUserScript(
                source: Self.interfaceScript(name: name, asyncMethods: methods),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
    }

    /// window[name]: void methods post a message (Android runs them in the
    /// background); the rest block on prompt() and return Java's value.
    private static func interfaceScript(name: String, asyncMethods: [String: Int]) -> String {
        let asyncNames = asyncMethods.keys.map { "\(WebKitBridge.javascriptLiteral($0)):1" }
            .joined(separator: ",")
        return """
        (function(){var n=\(WebKitBridge.javascriptLiteral(name)),a={\(asyncNames)};\
        function e(v){try{return btoa(unescape(encodeURIComponent(String(v))))}catch(x){return ''}}\
        function p(m,g){var l=Array.prototype.slice.call(g);return m+'\\n'+l.length+'\\n'+l.map(e).join('\\t')}\
        var o=new Proxy({},{has:function(t,k){return typeof k==='string'},get:function(t,k){\
        if(typeof k!=='string')return undefined;\
        if(k==='toString')return function(){return '[object '+n+']'};\
        if(Object.prototype.hasOwnProperty.call(a,k))return function(){\
        window.webkit.messageHandlers.\(messageHandlerName).postMessage({n:n,p:p(k,arguments)})};\
        return function(){var r=prompt('\(syncBridgePrompt)'+n,p(k,arguments));\
        if(r===null||r===undefined)return undefined;try{return JSON.parse(r)}catch(x){return r}}}});\
        try{Object.defineProperty(window,n,{value:o,configurable:true,writable:true})}catch(x){window[n]=o}})();
        """
    }

    /// WKWebView has no shouldInterceptRequest. Extensions that watch the page's own
    /// requests (to know the site is loading data, or to pace it) at least learn of its
    /// fetch and XHR calls: the page reports each one, and Java hears of it as
    /// shouldInterceptRequest whose answer is ignored, as the request already went out.
    private static let requestObserver = WKUserScript(
        source: """
        (function(){if(window.__wizardRequests)return;window.__wizardRequests=1;\
        function r(u,m){try{window.webkit.messageHandlers.\(messageHandlerName).postMessage(\
        {r:new URL(String(u),location.href).href,m:String(m||'GET').toUpperCase()})}catch(e){}}\
        var f=window.fetch;if(f){window.fetch=function(i,o){try{r(i&&i.url?i.url:i,\
        (o&&o.method)||(i&&i.method))}catch(e){}return f.apply(this,arguments)}}\
        var x=XMLHttpRequest.prototype,op=x.open,sd=x.send;\
        x.open=function(m,u){this.__wizardR=[u,m];return op.apply(this,arguments)};\
        x.send=function(){if(this.__wizardR)r(this.__wizardR[0],this.__wizardR[1]);\
        return sd.apply(this,arguments)};\
        ['log','info','warn','error'].forEach(function(k){var o=console[k];console[k]=function(){\
        try{var t=Array.prototype.map.call(arguments,function(v){try{return typeof v==='string'?v:JSON.stringify(v)}\
        catch(e){return String(v)}}).join(' ');window.webkit.messageHandlers.\(messageHandlerName)\
        .postMessage({c:k,t:t.slice(0,4000)})}catch(e){}return o.apply(this,arguments)}});\
        window.addEventListener('error',function(e){try{window.webkit.messageHandlers.\(messageHandlerName)\
        .postMessage({c:'error',t:String(e.message)+' ('+e.filename+':'+e.lineno+')'})}catch(x){}})})();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    func received(_ message: WKScriptMessage) {
        if let body = message.body as? [String: Any], let level = body["c"] as? String {
            WebViewLog.shared.add(level: level, text: body["t"] as? String ?? "",
                                  page: message.frameInfo.request.url?.host ?? "")
            return
        }
        if let body = message.body as? [String: Any], let address = body["r"] as? String {
            let method = body["m"] as? String ?? "GET"
            let isMain = message.frameInfo.isMainFrame
            let payload = [
                WebKitBridge.encode(address), WebKitBridge.encode(method), String(isMain),
            ].joined(separator: "\n")
            let handle = self.handle
            WebKitBridge.events.async {
                _ = WebKitBridge.send(handle, "requestSeen", payload)
            }
            WebViewLog.shared.add(level: "request", text: "\(method) \(address)",
                                  page: message.frameInfo.request.url?.host ?? "")
            return
        }
        guard let body = message.body as? [String: Any],
              let name = body["n"] as? String,
              let payload = body["p"] as? String
        else { return }
        let handle = self.handle
        WebKitBridge.events.async {
            _ = WebKitBridge.send(handle, "jsBridge", name, payload)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let url = navigationAction.request.url?.absoluteString ?? ""
        if programmaticLoadPending && mainFrame && navigationAction.navigationType != .linkActivated {
            programmaticLoadPending = false
            decisionHandler(.allow)
            return
        }
        guard mainFrame, !url.hasPrefix("about:") else {
            decisionHandler(.allow)
            return
        }
        let payload = WebKitBridge.encodeRequest(
            url: url,
            method: navigationAction.request.httpMethod ?? "GET",
            mainFrame: true,
            redirect: navigationAction.navigationType == .other,
            gesture: navigationAction.navigationType == .linkActivated,
            headers: navigationAction.request.allHTTPHeaderFields ?? [:]
        )
        let handle = self.handle
        WebKitBridge.replies.async {
            let answer = WebKitBridge.send(handle, "shouldOverride", payload)
            Task { @MainActor in
                decisionHandler(answer == "true" ? .cancel : .allow)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        sendEvent("progress", "10")
    }

    /// The new document exists from here on: scripts the extension evaluates on
    /// onPageStarted land in it, as they do on Android.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sendEvent("pageStarted", webView.url?.absoluteString ?? "")
        sendEvent("progress", "50")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        sendEvent("progress", "100")
        if let title = webView.title, !title.isEmpty {
            sendEvent("title", title)
        }
        sendEvent("pageFinished", url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        sendEvent("renderGone", "true")
    }

    private func reportError(_ error: Error) {
        let error = error as NSError
        // Cancelled loads and policy cancellations are not page errors on Android.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        let url = (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? webView.url?.absoluteString ?? ""
        let request = WebKitBridge.encodeRequest(
            url: url, method: "GET", mainFrame: true, redirect: false, gesture: false, headers: [:]
        )
        let details = "\(Self.androidErrorCode(error))\n\(WebKitBridge.encode(error.localizedDescription))"
        sendEvent("error", request, details)
    }

    /// WebViewClient.ERROR_* for the common NSURLError codes.
    private static func androidErrorCode(_ error: NSError) -> Int {
        guard error.domain == NSURLErrorDomain else { return -1 }
        switch error.code {
            case NSURLErrorTimedOut: return -8
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return -2
            case NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost: return -6
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot: return -11
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return -12
            case NSURLErrorHTTPTooManyRedirects: return -9
            default: return -1
        }
    }

    private func sendEvent(_ event: String, _ first: String? = nil, _ second: String? = nil) {
        let handle = self.handle
        WebKitBridge.events.async {
            _ = WebKitBridge.send(handle, event, first, second)
        }
    }

    // MARK: WKUIDelegate

    /// window.open: Android keeps it in the same WebView unless told otherwise.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// The synchronous half of addJavascriptInterface (methods that return a value).
    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard prompt.hasPrefix(Self.syncBridgePrompt) else {
            completionHandler(nil)
            return
        }
        let name = String(prompt.dropFirst(Self.syncBridgePrompt.count))
        let payload = defaultText ?? ""
        let handle = self.handle
        WebKitBridge.replies.async {
            let answer = WebKitBridge.send(handle, "jsBridgeSync", name, payload)
            let value = answer.flatMap { $0.hasPrefix("__ERROR__") ? nil : $0 } ?? "null"
            Task { @MainActor in completionHandler(value) }
        }
    }

    /// Nobody sees these WebViews: dialogs answer at once.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }
}

/// WKUserContentController retains its handlers: this breaks the cycle.
@MainActor
final class BridgeMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BridgedWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.received(message)
    }
}

// MARK: - Cookies

/// Android's CookieManager over WebKit's shared cookie store, so cookies a
/// WebView receives (Cloudflare clearance included) are the ones Java reads.
@MainActor
enum WebKitCookies {
    private static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    static func run(_ operation: String, _ first: String?, _ second: String?, completion: @escaping (String) -> Void) {
        switch operation {
            case "cookieGet":
                guard let url = normalized(first) else {
                    completion("")
                    return
                }
                store.getAllCookies { cookies in
                    let header = cookies
                        .filter { matches($0, url: url) }
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    completion(header)
                }
            case "cookieSet":
                guard let url = normalized(first), let value = second else {
                    completion("false")
                    return
                }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url)
                guard !cookies.isEmpty else {
                    completion("false")
                    return
                }
                let group = DispatchGroup()
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
                group.notify(queue: .main) { completion("true") }
            case "cookieRemoveSession", "cookieRemoveAll":
                let sessionOnly = operation == "cookieRemoveSession"
                store.getAllCookies { cookies in
                    let doomed = cookies.filter { !sessionOnly || $0.isSessionOnly }
                    guard !doomed.isEmpty else {
                        completion("false")
                        return
                    }
                    let group = DispatchGroup()
                    for cookie in doomed {
                        HTTPCookieStorage.shared.deleteCookie(cookie)
                        group.enter()
                        store.delete(cookie) { group.leave() }
                    }
                    group.notify(queue: .main) { completion("true") }
                }
            case "cookieHas":
                store.getAllCookies { completion(String(!$0.isEmpty)) }
            default:
                // cookieFlush: WebKit persists on its own.
                completion("")
        }
    }

    nonisolated private static func normalized(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value.hasPrefix("http") ? value : "https://" + value)
    }

    nonisolated private static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        if cookie.isSecure && url.scheme != "https" { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return cookie.path == "/" || path.hasPrefix(cookie.path)
    }
}

// MARK: - Log

/// What the extensions' hidden pages printed and requested, last lines only, for
/// diagnosing a source that fails (Ajustes → Registro de WebView). Memory only.
@MainActor
final class WebViewLog: ObservableObject {
    static let shared = WebViewLog()

    struct Line: Identifiable {
        let id = UUID()
        let date: Date
        let level: String
        let page: String
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private let limit = 400

    func add(level: String, text: String, page: String) {
        lines.append(Line(date: Date(), level: level, page: page, text: text))
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func clear() { lines.removeAll() }

    var text: String {
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss"
        return lines.map { "\(format.string(from: $0.date)) [\($0.level)] \($0.page) \($0.text)" }
            .joined(separator: "\n")
    }
}
