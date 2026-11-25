import XCTest
@testable import TTMailer

final class RichPushTests: XCTestCase {
    func u(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Payload

    func testAPushWithoutAnActionReturnsTheLinkLikeOpened() {
        let p = RichPush(["ttmToken": "tok", "redirectUrl": "storky://feed"], linkKey: "redirectUrl")
        XCTAssertEqual(p.token, "tok")
        XCTAssertEqual(p.action, .app)
        XCTAssertEqual(p.step, .returnLink(u("storky://feed")))
    }

    func testAnUnknownActionIsApp() {
        let p = RichPush(["ttmAction": "hologram", "ttmUrl": "https://x.example/a", "redirectUrl": "https://x.example/r"], linkKey: "redirectUrl")
        XCTAssertEqual(p.action, .app)
        XCTAssertEqual(p.step, .returnLink(u("https://x.example/r")))
    }

    func testAPushFromAnotherSourceWithoutLinkReturnsNil() {
        XCTAssertEqual(RichPush(["aps": ["alert": "hi"]], linkKey: "redirectUrl").step, .returnLink(nil))
        XCTAssertEqual(RichPush(["redirectUrl": "not a url"], linkKey: "redirectUrl").step, .returnLink(nil))
    }

    func testTheProjectsLinkKeyIsUsed() {
        let p = RichPush(["link": "https://x.example/a", "redirectUrl": "https://wrong.example"], linkKey: "link")
        XCTAssertEqual(p.link, u("https://x.example/a"))
    }

    func testBrowserOpensTheRawTargetNotTheTrackingLink() {
        let p = RichPush(["ttmAction": "browser", "ttmUrl": "https://shop.example/sale",
                          "redirectUrl": "https://mailer.example/r/abc"], linkKey: "redirectUrl")
        XCTAssertEqual(p.step, .openSystem(u("https://shop.example/sale")))
    }

    func testBrowserWithoutTtmUrlFallsBackToTheLink() {
        let p = RichPush(["ttmAction": "browser", "redirectUrl": "https://mailer.example/r/abc"], linkKey: "redirectUrl")
        XCTAssertEqual(p.step, .openSystem(u("https://mailer.example/r/abc")))
    }

    func testBrowserWithAStoreLinkOpensTheStore() {
        let p = RichPush(["ttmAction": "browser", "ttmUrl": "https://apps.apple.com/app/id123"], linkKey: "redirectUrl")
        XCTAssertEqual(p.step, .openStore(u("https://apps.apple.com/app/id123")))
    }

    func testInappOpensSafariViewControllerAndStoreLinksTheStore() {
        XCTAssertEqual(RichPush(["ttmAction": "inapp", "ttmUrl": "https://blog.example/post"], linkKey: "redirectUrl").step,
                       .openInAppBrowser(u("https://blog.example/post")))
        XCTAssertEqual(RichPush(["ttmAction": "inapp", "ttmUrl": "itms-apps://apps.apple.com/app/id1"], linkKey: "redirectUrl").step,
                       .openStore(u("itms-apps://apps.apple.com/app/id1")))
        XCTAssertEqual(RichPush(["ttmAction": "inapp", "ttmUrl": "https://play.google.com/store/apps/details?id=x"], linkKey: "redirectUrl").step,
                       .openStore(u("https://play.google.com/store/apps/details?id=x")))
    }

    func testInappWithANonWebLinkGoesToTheSystem() {
        XCTAssertEqual(RichPush(["ttmAction": "inapp", "ttmUrl": "storky://x"], linkKey: "redirectUrl").step, .openSystem(u("storky://x")))
    }

    func testMessageShowsTheMessageUrl() {
        let p = RichPush(["ttmAction": "message", "ttmUrl": "https://mailer.example/p/m/tok",
                          "redirectUrl": "https://mailer.example/p/m/tok", "ttmToken": "tok"], linkKey: "redirectUrl")
        XCTAssertEqual(p.step, .showMessage(u("https://mailer.example/p/m/tok")))
    }

    func testMessageWithoutAWebUrlReturnsTheLink() {
        XCTAssertEqual(RichPush(["ttmAction": "message"], linkKey: "redirectUrl").step, .returnLink(nil))
    }

    func testActionsWithoutAnyUrlReturnNil() {
        XCTAssertEqual(RichPush(["ttmAction": "browser"], linkKey: "redirectUrl").step, .returnLink(nil))
        XCTAssertEqual(RichPush(["ttmAction": "inapp"], linkKey: "redirectUrl").step, .returnLink(nil))
    }

    func testEmptyTokenIsNoToken() {
        XCTAssertNil(RichPush(["ttmToken": ""], linkKey: "redirectUrl").token)
    }

    // MARK: - Store URLs

    func testStoreUrls() {
        for s in ["https://apps.apple.com/cz/app/bibino/id123", "http://itunes.apple.com/app/id123", "https://APPS.apple.com/x",
                  "https://play.google.com/store/apps/details?id=com.x", "https://play.google.com/store",
                  "itms-apps://apps.apple.com/app/id1", "itms-appss://x", "market://details?id=com.x"] {
            XCTAssertTrue(StoreURL.isStore(u(s)), s)
        }
        for s in ["https://play.google.com/books", "https://google.com/store", "https://apple.com/app",
                  "https://example.com/apps.apple.com", "storky://store", "ftp://apps.apple.com/x"] {
            XCTAssertFalse(StoreURL.isStore(u(s)), s)
        }
    }

    // MARK: - Navigation in the message

    let hosts: Set<String> = ["mailer.example"]
    func decide(_ s: String, main: Bool = true) -> MessageNavigation { MessageNavigation.decide(u(s), mainFrame: main, ttmailerHosts: hosts) }

    func testTtmailerPagesAndClickRedirectsStayInTheWebView() {
        XCTAssertEqual(decide("https://mailer.example/p/m/tok"), .allow)
        XCTAssertEqual(decide("https://MAILER.example/c/abc"), .allow)
        XCTAssertEqual(decide("http://mailer.example/c/abc"), .allow)
        XCTAssertEqual(decide("about:blank"), .allow)
    }

    func testTheFinalTargetsAreHandledOutside() {
        XCTAssertEqual(decide("ttmailer://close"), .close)
        XCTAssertEqual(decide("TTMAILER://close"), .close)
        XCTAssertEqual(decide("ttmailer://other"), .cancel)
        XCTAssertEqual(decide("https://apps.apple.com/app/id1"), .store(u("https://apps.apple.com/app/id1")))
        XCTAssertEqual(decide("market://details?id=x"), .store(u("market://details?id=x")))
        XCTAssertEqual(decide("https://shop.example/sale"), .browser(u("https://shop.example/sale")))
        XCTAssertEqual(decide("storky://premium"), .deepLink(u("storky://premium")))
        XCTAssertEqual(decide("mailto:a@b.cz"), .deepLink(u("mailto:a@b.cz")))
    }

    func testOtherHostsAreNotTtmailer() {
        XCTAssertEqual(decide("https://evil.mailer.example.com/x"), .browser(u("https://evil.mailer.example.com/x")))
    }

    func testNothingRunsScripts() {
        XCTAssertEqual(decide("javascript:alert(1)"), .cancel)
        XCTAssertEqual(decide("data:text/html,hi"), .cancel)
    }

    func testFramesNeverLeaveTheWebView() {
        XCTAssertEqual(decide("https://video.example/embed", main: false), .allow)
        XCTAssertEqual(decide("storky://x", main: false), .cancel)
        XCTAssertEqual(decide("https://apps.apple.com/app/id1", main: false), .allow)
        XCTAssertEqual(decide("ttmailer://close", main: false), .close)
    }

    // MARK: - Texts

    func testTextsInTheAppsLanguage() {
        XCTAssertEqual(MessageStrings.forLanguage("cs").tryAgain, "Zkusit znovu")
        XCTAssertEqual(MessageStrings.forLanguage("cs-CZ").tryAgain, "Zkusit znovu")
        XCTAssertEqual(MessageStrings.forLanguage("pt_BR").tryAgain, "Tentar novamente")
        XCTAssertEqual(MessageStrings.forLanguage("ja").tryAgain, "Try again")
        XCTAssertEqual(MessageStrings.forLanguage(nil).tryAgain, "Try again")
    }
}
