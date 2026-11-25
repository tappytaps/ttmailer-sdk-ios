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

    let hosts: Set<String> = ["mailer.example", "pub.mailer.example"]
    let schemes: Set<String> = ["storky", "fb123"]
    func decide(_ s: String, main: Bool = true, header: Bool = true, initial: Bool = false) -> MessageNavigation {
        MessageNavigation.decide(u(s), mainFrame: main, ttmailerHosts: hosts, appSchemes: schemes, hasHeader: header, initialBlank: initial)
    }

    func testTtmailerPagesAndClickRedirectsStayInTheWebView() {
        XCTAssertEqual(decide("https://mailer.example/p/m/tok"), .allow)
        XCTAssertEqual(decide("https://MAILER.example/c/abc"), .allow)
        XCTAssertEqual(decide("https://pub.mailer.example/c/abc"), .allow)
    }

    func testATtmailerLoadWithoutTheHeaderIsLoadedAgainWithIt() {
        XCTAssertEqual(decide("https://mailer.example/c/abc", header: false), .reloadWithHeader)
        XCTAssertEqual(decide("https://shop.example/x", header: false), .browser(u("https://shop.example/x")))
    }

    func testTtmailerHostsAreHttpsOnlyAndExact() {
        XCTAssertEqual(decide("http://mailer.example/c/abc"), .browser(u("http://mailer.example/c/abc")))
        XCTAssertEqual(decide("https://evil.mailer.example.com/x"), .browser(u("https://evil.mailer.example.com/x")))
        XCTAssertEqual(decide("https://x.mailer.example/x"), .browser(u("https://x.mailer.example/x")))
    }

    func testTheFinalTargetsAreHandledOutside() {
        XCTAssertEqual(decide("ttmailer://close"), .close)
        XCTAssertEqual(decide("TTMAILER://close"), .close)
        XCTAssertEqual(decide("ttmailer://other"), .cancel)
        XCTAssertEqual(decide("https://apps.apple.com/app/id1"), .store(u("https://apps.apple.com/app/id1")))
        XCTAssertEqual(decide("market://details?id=x"), .store(u("market://details?id=x")))
        XCTAssertEqual(decide("https://shop.example/sale"), .browser(u("https://shop.example/sale")))
    }

    func testOnlyTheAppsOwnSchemesAreDeepLinks() {
        XCTAssertEqual(decide("storky://premium"), .deepLink(u("storky://premium")))
        XCTAssertEqual(decide("STORKY://premium"), .deepLink(u("STORKY://premium")))
        XCTAssertEqual(decide("fb123://auth"), .deepLink(u("fb123://auth")))
        for s in ["mailto:a@b.cz", "tel:+420123", "sms:+420123", "maps://?q=Brno", "facetime://a@b.cz", "otherapp://x"] {
            XCTAssertEqual(decide(s), .system(u(s)), s)
        }
    }

    func testNothingRunsScriptsOrLocalFiles() {
        for s in ["javascript:alert(1)", "data:text/html,hi", "blob:https://mailer.example/1", "file:///etc/passwd",
                  "content://x", "about:srcdoc", "about:blank"] {
            XCTAssertEqual(decide(s), .cancel, s)
        }
        XCTAssertEqual(decide("about:blank", initial: true), .allow)
        XCTAssertEqual(decide("about:srcdoc", initial: true), .cancel)
    }

    func testFramesNeverLeaveTheWebViewAndNeverClose() {
        XCTAssertEqual(decide("https://video.example/embed", main: false), .allow)
        XCTAssertEqual(decide("https://mailer.example/x", main: false, header: false), .allow)
        XCTAssertEqual(decide("https://apps.apple.com/app/id1", main: false), .allow)
        XCTAssertEqual(decide("storky://x", main: false), .cancel)
        XCTAssertEqual(decide("mailto:a@b.cz", main: false), .cancel)
        XCTAssertEqual(decide("ttmailer://close", main: false), .cancel)
        XCTAssertEqual(decide("javascript:alert(1)", main: false), .cancel)
    }

    func testTheAppsSchemesComeFromInfoPlist() {
        let info: [String: Any] = ["CFBundleURLTypes": [
            ["CFBundleURLName": "main", "CFBundleURLSchemes": ["Storky", "storky-dev"]],
            ["CFBundleURLSchemes": ["fb123"]],
            ["CFBundleURLName": "broken"],
        ]]
        XCTAssertEqual(MessageNavigation.appSchemes(info), ["storky", "storky-dev", "fb123"])
        XCTAssertEqual(MessageNavigation.appSchemes(nil), [])
        XCTAssertEqual(MessageNavigation.appSchemes(["CFBundleURLTypes": "x"]), [])
    }

    // MARK: - Loading the message

    func testErrorsReplaceTheMessageOnlyOnTheFirstLoad() {
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, status: 200), .ok)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, status: 302), .ok)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, status: 404), .errorView)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, status: 500), .errorView)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: true, status: 500), .notice)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, error: URLError(.notConnectedToInternet)), .errorView)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: true, error: URLError(.notConnectedToInternet)), .notice)
    }

    func testNavigationsTheSdkCancelledAreNoErrors() {
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, error: URLError(.cancelled)), .ignore)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, error: NSError(domain: "WebKitErrorDomain", code: 102)), .ignore)
        XCTAssertEqual(MessageLoad.outcome(loadedOnce: false, error: NSError(domain: "WebKitErrorDomain", code: 101)), .errorView)
    }

    // MARK: - Texts

    func testTextsInTheAppsLanguage() {
        XCTAssertEqual(MessageStrings.forLanguage("cs").tryAgain, "Zkusit znovu")
        XCTAssertEqual(MessageStrings.forLanguage("cs-CZ").tryAgain, "Zkusit znovu")
        XCTAssertEqual(MessageStrings.forLanguage("pt_BR").tryAgain, "Tentar novamente")
        XCTAssertEqual(MessageStrings.forLanguage("ja").tryAgain, "Try again")
        XCTAssertEqual(MessageStrings.forLanguage(nil).tryAgain, "Try again")
        XCTAssertEqual(MessageStrings.forLanguage("cs").loading, "Načítání zprávy")
        XCTAssertEqual(MessageStrings.forLanguage("en").loaded, "Message loaded")
    }
}
