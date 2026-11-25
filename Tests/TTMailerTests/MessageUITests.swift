#if os(iOS)
import XCTest
import UIKit
import WebKit
@testable import TTMailer

/// UIKit on the iOS simulator (no host app: windows work, the app object does not).
@MainActor
final class MessageUITests: XCTestCase {
    var windows: [UIWindow] = []

    func onScreen(_ vc: UIViewController) -> UIViewController {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        w.rootViewController = vc
        w.isHidden = false
        windows.append(w)
        return vc
    }

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows = []
    }

    // MARK: - Presenter

    func testThePresenterIsTheTopmostPresentedViewController() {
        let root = onScreen(UIViewController())
        XCTAssertTrue(RichPushUI.isReady(root))
        XCTAssertTrue(RichPushUI.readyPresenter(root) === root)
        let sheet = UIViewController()
        root.present(sheet, animated: false)
        XCTAssertTrue(RichPushUI.topmost(from: root) === sheet)
        XCTAssertFalse(RichPushUI.isReady(root), "root already presents")
    }

    func testAnAlertIsNeverThePresenter() {
        let root = onScreen(UIViewController())
        root.present(UIAlertController(title: "x", message: nil, preferredStyle: .alert), animated: false)
        XCTAssertTrue(RichPushUI.topmost(from: root) === root)
        XCTAssertNil(RichPushUI.readyPresenter(root), "presenting over an alert fails: wait for it")
    }

    func testAViewControllerOffScreenIsNotReady() {
        let vc = UIViewController()
        XCTAssertFalse(RichPushUI.isReady(vc))
        vc.loadViewIfNeeded()
        XCTAssertFalse(RichPushUI.isReady(vc))
        XCTAssertNil(RichPushUI.readyPresenter(vc))
    }

    // MARK: - The message screen

    let html = """
    <html><body>
    <a id="blank" href="https://shop.example/sale" target="_blank">sale</a>
    <a id="close" href="ttmailer://close">close</a>
    <a id="deep" href="storky://premium">premium</a>
    <a id="mail" href="mailto:a@b.cz">mail</a>
    <a id="store" href="https://apps.apple.com/app/id1">store</a>
    </body></html>
    """

    func message(html: String? = nil) -> TTMailerMessageViewController {
        let vc = TTMailerMessageViewController(url: URL(string: "https://mailer.example/p/m/tok")!,
                                               ttmailerHosts: ["mailer.example"], appSchemes: ["storky"])
        vc.testHTML = html
        return vc
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), what)
    }

    func loaded(_ vc: TTMailerMessageViewController) async {
        _ = onScreen(UINavigationController(rootViewController: vc))
        vc.loadViewIfNeeded()
        await waitUntil("the test page loads") { vc.loadedOnce }
    }

    func click(_ id: String, in vc: TTMailerMessageViewController) async -> MessageNavigation? {
        final class Box { var value: MessageNavigation? }
        let got = Box()
        vc.externalHandler = { got.value = $0 }
        _ = try? await vc.webView.evaluateJavaScript("document.getElementById('\(id)').click(); true")
        await waitUntil("a navigation for #\(id)") { got.value != nil }
        return got.value
    }

    func testTheMessageLoadsWithJavaScriptOff() async {
        let vc = message(html: html)
        await loaded(vc)
        XCTAssertFalse(vc.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(vc.errorView.isHidden)
        XCTAssertFalse(vc.spinner.isAnimating)
        XCTAssertNotNil(vc.spinner.accessibilityLabel)
    }

    func testABlankTargetExternalLinkGoesOutside() async {
        let vc = message(html: html)
        await loaded(vc)
        let nav = await click("blank", in: vc)
        XCTAssertEqual(nav, .browser(URL(string: "https://shop.example/sale")!))
    }

    func testLinksInTheMessage() async {
        let vc = message(html: html)
        await loaded(vc)
        let close = await click("close", in: vc)
        XCTAssertEqual(close, .close)
        let deep = await click("deep", in: vc)
        XCTAssertEqual(deep, .deepLink(URL(string: "storky://premium")!))
        let mail = await click("mail", in: vc)
        XCTAssertEqual(mail, .system(URL(string: "mailto:a@b.cz")!))
        let store = await click("store", in: vc)
        XCTAssertEqual(store, .store(URL(string: "https://apps.apple.com/app/id1")!))
        XCTAssertTrue(vc.errorView.isHidden, "links handled outside are no errors")
    }

    func testAnHttpErrorOnTheFirstLoadShowsTheErrorView() {
        let vc = message(html: "<p>x</p>")
        vc.externalHandler = { _ in }
        vc.loadViewIfNeeded()
        XCTAssertFalse(vc.loadResult(status: 404))
        XCTAssertFalse(vc.errorView.isHidden)
        XCTAssertTrue(vc.webView.isHidden)
    }

    func testAnErrorAfterTheMessageLoadedKeepsTheMessage() async {
        let vc = message(html: html)
        await loaded(vc)
        XCTAssertFalse(vc.loadResult(status: 500))
        XCTAssertFalse(vc.loadResult(error: URLError(.notConnectedToInternet)))
        XCTAssertTrue(vc.errorView.isHidden)
        XCTAssertFalse(vc.webView.isHidden)
        XCTAssertFalse(vc.noticeLabel.isHidden)
    }

    func testNoNetworkOnTheFirstLoadShowsTheErrorView() {
        let vc = message(html: "<p>x</p>")
        vc.loadViewIfNeeded()
        vc.loadResult(error: URLError(.notConnectedToInternet))
        XCTAssertFalse(vc.errorView.isHidden)
    }
}
#endif
