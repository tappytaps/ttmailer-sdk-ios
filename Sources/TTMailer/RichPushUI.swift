#if canImport(UIKit) && canImport(WebKit) && canImport(SafariServices) && os(iOS)
import UIKit
import WebKit
import SafariServices

@available(iOSApplicationExtension, unavailable)
extension TTMailer {
    /// Call when the user taps a notification (`userNotificationCenter(_:didReceive:)` →
    /// `response.notification.request.content.userInfo`). Reports the open to TTMailer, then does what the push asks for
    /// (`ttmAction`): opens the link in the browser, in the in-app browser (store links in the store), or shows the
    /// in-app message. Returns the push's link only when the app should open it itself (an ordinary push, or a push from
    /// another source), like `opened(_:)`; nil when the SDK handled the tap.
    /// - Parameter presenter: the view controller to present the in-app browser or the message from; by default the
    ///   key window's top view controller.
    @MainActor @discardableResult
    public static func handle(_ userInfo: [AnyHashable: Any], from presenter: UIViewController? = nil) -> URL? {
        let e = current
        let push = RichPush(userInfo, linkKey: e?.linkKey ?? defaultLinkKey)
        if let e {
            let token = push.token
            Task { _ = await e.opened(token.map { ["ttmToken": $0] } ?? [:]); await e.flushOpens() }
        }
        switch push.step {
        case .returnLink(let link):
            return link
        case .openSystem(let url), .openStore(let url):
            UIApplication.shared.open(url)
        case .openInAppBrowser(let url):
            if let p = presenter ?? topViewController() {
                RichPushUI.presentBrowser(url, from: p)
            } else {
                UIApplication.shared.open(url)
            }
        case .showMessage(let url):
            if let p = presenter ?? topViewController() {
                var hosts = Set<String>()
                if let h = (e?.baseURL ?? defaultBaseURL).host?.lowercased() { hosts.insert(h) }
                if let h = url.host?.lowercased() { hosts.insert(h) }
                let vc = TTMailerMessageViewController(url: url, ttmailerHosts: hosts)
                let nav = UINavigationController(rootViewController: vc)
                nav.modalPresentationStyle = .fullScreen
                p.present(nav, animated: true)
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    /// The key window's top view controller.
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow)
            ?? scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first
            ?? windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

@available(iOSApplicationExtension, unavailable)
enum RichPushUI {
    @MainActor
    static func presentBrowser(_ url: URL, from presenter: UIViewController) {
        guard StoreURL.isWeb(url) else { UIApplication.shared.open(url); return }
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(SFSafariViewController(url: url), animated: true)
    }
}

/// The in-app message: a full-screen web view (JavaScript off) with a close button, a loading state and an error view.
@available(iOSApplicationExtension, unavailable)
final class TTMailerMessageViewController: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let ttmailerHosts: Set<String>
    private let strings = MessageStrings.forLanguage(Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first)
    private var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorView = UIStackView()
    private var closing = false

    init(url: URL, ttmailerHosts: Set<String>) {
        self.url = url
        self.ttmailerHosts = ttmailerHosts
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let close = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        close.accessibilityLabel = strings.close
        navigationItem.rightBarButtonItem = close

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.allowsLinkPreview = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        let label = UILabel()
        label.text = strings.error
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        let retry = UIButton(type: .system)
        retry.setTitle(strings.tryAgain, for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        errorView.addArrangedSubview(label)
        errorView.addArrangedSubview(retry)
        errorView.axis = .vertical
        errorView.alignment = .center
        errorView.spacing = 16
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorView)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: g.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: g.centerYAnchor),
            errorView.centerYAnchor.constraint(equalTo: g.centerYAnchor),
            errorView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 32),
            errorView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -32),
        ])
        load()
    }

    /// Loads the message; TTMailer learns from the header that it is shown in the SDK (and shows its close links).
    private func load() {
        errorView.isHidden = true
        webView.isHidden = false
        spinner.startAnimating()
        var request = URLRequest(url: url)
        request.setValue(TTMailer.sdkVersion, forHTTPHeaderField: "X-TTMailer-SDK")
        webView.load(request)
    }

    private func showError() {
        spinner.stopAnimating()
        webView.stopLoading()
        webView.isHidden = true
        errorView.isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: errorView)
    }

    @objc private func retryTapped() { load() }

    @objc private func closeTapped() { dismissMessage(then: nil) }

    /// Dismisses the message together with anything presented over it (the in-app browser).
    private func dismissMessage(then completion: (() -> Void)?) {
        guard !closing else { return }
        closing = true
        let root = navigationController ?? self
        if let presenter = root.presentingViewController {
            presenter.dismiss(animated: true, completion: completion)
        } else {
            completion?()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch MessageNavigation.decide(target, mainFrame: mainFrame, ttmailerHosts: ttmailerHosts) {
        case .allow:
            if navigationAction.targetFrame == nil {
                // target="_blank": load it here instead of a new window.
                decisionHandler(.cancel)
                webView.load(navigationAction.request)
            } else {
                decisionHandler(.allow)
            }
        case .cancel:
            decisionHandler(.cancel)
        case .close:
            decisionHandler(.cancel)
            dismissMessage(then: nil)
        case .store(let u):
            decisionHandler(.cancel)
            UIApplication.shared.open(u)
        case .browser(let u):
            decisionHandler(.cancel)
            RichPushUI.presentBrowser(u, from: navigationController ?? self)
        case .deepLink(let u):
            decisionHandler(.cancel)
            dismissMessage {
                if let handler = TTMailer.onDeepLink { handler(u) } else { UIApplication.shared.open(u) }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel)
            showError()
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showError()
    }

    private func failed(_ error: Error) {
        spinner.stopAnimating()
        let e = error as NSError
        // A navigation the SDK cancelled itself (a link handled outside, an HTTP error already shown) is no error.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return } // WebKitErrorFrameLoadInterruptedByPolicyChange
        if !errorView.isHidden { return }
        showError()
    }
}
#endif
