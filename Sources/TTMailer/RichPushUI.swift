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
    /// - Parameter presenter: the view controller to present the in-app browser or the message from (the SDK presents
    ///   over whatever it already presents); by default the key window's top view controller. When the app's UI is not
    ///   on screen yet (a cold start from the push), the SDK waits up to 5 seconds for it.
    @MainActor @discardableResult
    public static func handle(_ userInfo: [AnyHashable: Any], from presenter: UIViewController? = nil) -> URL? {
        let e = current
        let push = RichPush(userInfo, linkKey: e?.linkKey ?? defaultLinkKey)
        if let e {
            let token = push.token
            Task { await e.recordOpen(token: token); await e.flushOpens() }
        }
        switch push.step {
        case .returnLink(let link):
            return link
        case .openSystem(let url):
            // A universal link may open its app instead of Safari (the system decides).
            UIApplication.shared.open(url, options: [.universalLinksOnly: false])
        case .openStore(let url):
            UIApplication.shared.open(url)
        case .openInAppBrowser(let url):
            RichPushUI.present(from: presenter, fallback: { UIApplication.shared.open(url) }) {
                SFSafariViewController(url: url)
            }
        case .showMessage(let url):
            var hosts = Set<String>()
            if let h = (e?.baseURL ?? defaultBaseURL).host?.lowercased() { hosts.insert(h) }
            if let h = url.host?.lowercased() { hosts.insert(h) }
            let schemes = MessageNavigation.appSchemes(Bundle.main.infoDictionary)
            // Never Safari instead of the message while the app is fine: only when its UI never came up, the web version.
            RichPushUI.present(from: presenter, fallback: { UIApplication.shared.open(url) }) {
                let vc = TTMailerMessageViewController(url: url, ttmailerHosts: hosts, appSchemes: schemes)
                let nav = UINavigationController(rootViewController: vc)
                nav.modalPresentationStyle = .fullScreen
                return nav
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
        guard let root = window?.rootViewController else { return nil }
        return RichPushUI.topmost(from: root)
    }
}

@available(iOSApplicationExtension, unavailable)
@MainActor
enum RichPushUI {
    /// How long a tap waits for the app's UI (a cold start).
    static var readinessTimeout: TimeInterval = 5
    private static var pending: PendingPresentation?

    /// The view controller to present from: the given one, or what it already presents (not an alert, not one going
    /// away).
    static func topmost(from vc: UIViewController) -> UIViewController {
        var top = vc
        while let next = top.presentedViewController, !(next is UIAlertController), !next.isBeingDismissed { top = next }
        return top
    }

    /// On screen and free to present (not mid-transition, not already presenting, e.g. an alert).
    static func isReady(_ vc: UIViewController) -> Bool {
        vc.viewIfLoaded?.window != nil && !vc.isBeingPresented && !vc.isBeingDismissed && vc.presentedViewController == nil
    }

    static func readyPresenter(_ given: UIViewController?) -> UIViewController? {
        guard let base = given ?? TTMailer.topViewController() else { return nil }
        let top = topmost(from: base)
        return isReady(top) ? top : nil
    }

    /// Presents `make()` as soon as a presenter is ready; when none is ready within the timeout, runs `fallback`.
    static func present(from given: UIViewController?, fallback: @escaping @MainActor () -> Void,
                        _ make: @escaping @MainActor () -> UIViewController) {
        pending?.stop()
        if let p = readyPresenter(given) {
            p.present(make(), animated: true)
            return
        }
        let waiting = PendingPresentation(given: given, deadline: Date().addingTimeInterval(readinessTimeout), make: make, fallback: fallback)
        pending = waiting
        waiting.start()
    }

    fileprivate static func finished(_ p: PendingPresentation) {
        if pending === p { pending = nil }
    }

    static func presentBrowser(_ url: URL, from presenter: UIViewController) {
        guard StoreURL.isWeb(url) else { UIApplication.shared.open(url); return }
        topmost(from: presenter).present(SFSafariViewController(url: url), animated: true)
    }
}

/// A tap waiting for the app's UI: tried when a scene or the app becomes active and every 0.25 s, until the deadline.
@available(iOSApplicationExtension, unavailable)
@MainActor
private final class PendingPresentation {
    private weak var given: UIViewController?
    private let hadPresenter: Bool
    private let deadline: Date
    private let make: @MainActor () -> UIViewController
    private let fallback: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var done = false

    init(given: UIViewController?, deadline: Date, make: @escaping @MainActor () -> UIViewController,
         fallback: @escaping @MainActor () -> Void) {
        self.given = given
        self.hadPresenter = given != nil
        self.deadline = deadline
        self.make = make
        self.fallback = fallback
    }

    func start() {
        let names = [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.attempt() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.attempt() }
        }
    }

    func attempt() {
        guard !done else { return }
        // The given presenter went away meanwhile: the key window's top view controller.
        let base = hadPresenter ? given : nil
        if let p = RichPushUI.readyPresenter(base) {
            stop()
            p.present(make(), animated: true)
        } else if Date() >= deadline {
            stop()
            fallback()
        }
    }

    func stop() {
        guard !done else { return }
        done = true
        timer?.invalidate()
        timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        RichPushUI.finished(self)
    }
}

/// The in-app message: a full-screen web view (JavaScript off) with a close button, a loading state and an error view.
@available(iOSApplicationExtension, unavailable)
final class TTMailerMessageViewController: UIViewController, WKNavigationDelegate {
    static let headerName = "X-TTMailer-SDK"

    private let url: URL
    private let ttmailerHosts: Set<String>
    private let appSchemes: Set<String>
    private let strings = MessageStrings.forLanguage(Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first)
    private(set) var webView: WKWebView!
    let spinner = UIActivityIndicatorView(style: .large)
    let errorView = UIStackView()
    let noticeLabel = UILabel()
    private(set) var loadedOnce = false
    /// Nothing committed yet: the web view's own about:blank may load.
    private var initialBlank = true
    /// The URL just loaded with the header (in case WebKit reports the navigation without it): not reloaded again.
    private var headerLoad: URL?
    private var closing = false
    /// Tests: receives the navigations handled outside the web view instead of carrying them out.
    var externalHandler: ((MessageNavigation) -> Void)?
    /// Tests: HTML loaded instead of the message URL (with the message URL as its base).
    var testHTML: String?

    init(url: URL, ttmailerHosts: Set<String>, appSchemes: Set<String>) {
        self.url = url
        self.ttmailerHosts = ttmailerHosts
        self.appSchemes = appSchemes
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
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = strings.loading
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

        // A short notice when a later load fails (the message stays).
        noticeLabel.text = strings.error
        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.textColor = .label
        noticeLabel.backgroundColor = .secondarySystemBackground
        noticeLabel.textAlignment = .center
        noticeLabel.numberOfLines = 0
        noticeLabel.layer.cornerRadius = 10
        noticeLabel.layer.masksToBounds = true
        noticeLabel.alpha = 0
        noticeLabel.isHidden = true
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noticeLabel)

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
            noticeLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            noticeLabel.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            noticeLabel.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -32),
            noticeLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        load()
    }

    /// Loads the message; TTMailer learns from the header that it is shown in the SDK (and shows its close links).
    private func load() {
        errorView.isHidden = true
        webView.isHidden = false
        spinner.startAnimating()
        headerLoad = url
        if let html = testHTML {
            webView.loadHTMLString(html, baseURL: url)
        } else {
            var request = URLRequest(url: url)
            request.setValue(TTMailer.sdkVersion, forHTTPHeaderField: Self.headerName)
            webView.load(request)
        }
    }

    private func showError() {
        spinner.stopAnimating()
        webView.stopLoading()
        webView.isHidden = true
        errorView.isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: errorView)
    }

    private func showNotice() {
        spinner.stopAnimating()
        noticeLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: strings.error)
        UIView.animate(withDuration: 0.2) { self.noticeLabel.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 3, options: []) {
            self.noticeLabel.alpha = 0
        } completion: { _ in
            self.noticeLabel.isHidden = true
        }
    }

    /// A failed load or the HTTP status of a main-frame response. False when the navigation is to be cancelled.
    @discardableResult
    func loadResult(status: Int? = nil, error: Error? = nil) -> Bool {
        switch MessageLoad.outcome(loadedOnce: loadedOnce, status: status, error: error) {
        case .ok: return true
        case .ignore: spinner.stopAnimating(); return true
        case .errorView: showError(); return false
        case .notice: showNotice(); return false
        }
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

    private func perform(_ navigation: MessageNavigation) {
        if let externalHandler { externalHandler(navigation); return }
        switch navigation {
        case .allow, .reloadWithHeader, .cancel:
            break
        case .close:
            dismissMessage(then: nil)
        case .store(let u), .system(let u):
            UIApplication.shared.open(u)
        case .browser(let u):
            RichPushUI.presentBrowser(u, from: navigationController ?? self)
        case .deepLink(let u):
            dismissMessage {
                if let handler = TTMailer.onDeepLink { handler(u) } else { UIApplication.shared.open(u) }
            }
        }
    }

    private func reload(_ request: URLRequest) {
        var r = request
        r.setValue(TTMailer.sdkVersion, forHTTPHeaderField: Self.headerName)
        headerLoad = r.url
        webView.load(r)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        var hasHeader = navigationAction.request.value(forHTTPHeaderField: Self.headerName) != nil
        if mainFrame, let expected = headerLoad, expected == target {
            hasHeader = true
            headerLoad = nil
        }
        let decision = MessageNavigation.decide(target, mainFrame: mainFrame, ttmailerHosts: ttmailerHosts,
                                                appSchemes: appSchemes, hasHeader: hasHeader, initialBlank: initialBlank)
        switch decision {
        case .allow:
            if navigationAction.targetFrame == nil {
                // target="_blank" to a TTMailer page: load it here instead of a new window.
                decisionHandler(.cancel)
                reload(navigationAction.request)
            } else {
                decisionHandler(.allow)
            }
        case .reloadWithHeader:
            decisionHandler(.cancel)
            reload(navigationAction.request)
        case .cancel:
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
            perform(decision)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
           !loadResult(status: http.statusCode) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        initialBlank = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
        guard errorView.isHidden, !loadedOnce else { return }
        loadedOnce = true
        UIAccessibility.post(notification: .screenChanged, argument: strings.loaded)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadResult(error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadResult(error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if loadedOnce { webView.reload() } else { showError() }
    }
}
#endif
