import XCTest
@testable import TTMailer

/// Tags, the app's own language (TTM-584) and premium (TTM-585).
final class ChangesTests: XCTestCase {
    let key = "tta_ABCDEFGHIJKLMNOPQRSTUVWX"
    let info = DeviceInfo(language: "cs-CZ", timeZone: "Europe/Prague", appVersion: "3.2.1", osVersion: "18.1")
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func engine(_ t: FakeTransport, _ s: MemoryStore) -> Engine {
        Engine(appKey: key, baseURL: URL(string: "https://mailer.example.com")!, linkKey: "redirectUrl",
               transport: t, store: s, deviceInfo: { [info] in info }, now: { [unowned self] in self.now }, retry: false)
    }

    // MARK: Language

    func testTheAppsLanguageReplacesTheSystemOneAndNilGoesBack() async throws {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        await e.setLanguage("de")
        XCTAssertEqual(t.sent.last!.json!["language"] as? String, "de")
        // Kept after a restart, and the default language of a sign-up.
        let again = engine(t, s)
        t.answer(200); t.answer(200, "{\"ok\":true,\"confirm\":true}")
        _ = try await again.subscribe(email: "a@b.cz", language: nil)
        XCTAssertEqual(t.sent.last!.json!["language"] as? String, "de")
        await again.setLanguage(nil)
        XCTAssertEqual(t.sent.last!.json!["language"] as? String, "cs-CZ")
    }

    // MARK: Tags

    func testTagsAreSentAfterTheInstallationLastChangeOfATagWins() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        // Offline: both changes wait and merge, the later one of a tag wins.
        t.fail()
        await e.addTags(["Sportovec", "beta"])
        t.fail()
        await e.removeTags(["beta", "old"])
        await e.flushChanges()
        let id = await e.installationId
        let tags = t.sent.filter { $0.path == "/sdk/v1/installations/\(id)/tags" }
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(t.sent.last(where: { $0.method == "PUT" }) != nil, true, "the installation first")
        XCTAssertEqual(tags[0].json?["add"] as? [String], ["sportovec"])
        XCTAssertEqual(tags[0].json?["remove"] as? [String], ["beta", "old"])
        let pending = await e.pendingTagCount
        XCTAssertEqual(pending, 0)
    }

    func testTagsWaitOfflineSurviveARestartAndA4xxDropsThem() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        _ = await e.sync()
        t.fail()
        await e.addTags(["a"])
        var pending = await e.pendingTagCount
        XCTAssertEqual(pending, 1)
        let again = engine(t, s)
        await again.flushChanges()
        pending = await again.pendingTagCount
        XCTAssertEqual(pending, 0)
        let body = t.sent.last!.json!
        XCTAssertEqual(body["add"] as? [String], ["a"])
        t.answer(400, "{\"error\":\"invalid_tags\"}")
        await again.addTags(["bad tag"])
        pending = await again.pendingTagCount
        XCTAssertEqual(pending, 0, "a 4xx is not retried")
    }

    func testAnUnknownInstallationKeepsTheTagsForTheNextSync() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        _ = await e.sync()
        t.answer(409, "{\"error\":\"unknown_installation\"}")
        await e.addTags(["a"])
        let pending = await e.pendingTagCount
        XCTAssertEqual(pending, 1)
    }

    // MARK: Premium

    func testSetPremiumSendsTheReportOnceUntilItChanges() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        let until = now.addingTimeInterval(30 * 86400)
        await e.setPremium(PremiumReport(until: until, lifetime: false, kind: "paid", startedAt: now, products: nil))
        let id = await e.installationId
        let sent = t.sent.filter { $0.path == "/sdk/v1/installations/\(id)/premium" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].json?["kind"] as? String, "paid")
        XCTAssertEqual(sent[0].json?["until"] as? String, Engine.iso(until))
        XCTAssertNil(sent[0].json?["lifetime"])
        await e.setPremium(PremiumReport(until: until, lifetime: false, kind: "paid", startedAt: now, products: nil))
        XCTAssertEqual(t.sent.filter { $0.path.hasSuffix("/premium") }.count, 1, "the same report is not sent again")
        await e.setPremium(PremiumReport(until: nil, lifetime: true, kind: "lifetime", startedAt: nil, products: ["pro"]))
        let last = t.sent.last!.json!
        XCTAssertEqual(last["lifetime"] as? Bool, true)
        XCTAssertEqual(last["products"] as? [String], ["pro"])
    }

    // MARK: Reading the store (pure)

    func testAnActiveSubscriptionIsPremiumUntilItsEnd() {
        let end = now.addingTimeInterval(20 * 86400), start = now.addingTimeInterval(-40 * 86400)
        let r = PremiumReport.from([Entitlement(productId: "m", kind: .subscription, expiresAt: end, originalPurchaseAt: start, trial: true)],
                                   lifetimeProducts: [], previous: nil, now: now)
        XCTAssertEqual(r, PremiumReport(until: end, lifetime: false, kind: "trial", startedAt: start, products: []))
    }

    func testALifetimeProductIsLifetimeOtherProductsOnlyTags() {
        let ents = [Entitlement(productId: "pro", kind: .oneTime, expiresAt: nil, originalPurchaseAt: now, trial: false),
                    Entitlement(productId: "themes", kind: .oneTime, expiresAt: nil, originalPurchaseAt: now, trial: false)]
        let r = PremiumReport.from(ents, lifetimeProducts: ["pro"], previous: nil, now: now)
        XCTAssertEqual(r, PremiumReport(until: nil, lifetime: true, kind: "lifetime", startedAt: now, products: ["pro", "themes"]))
        let only = PremiumReport.from([ents[1]], lifetimeProducts: [], previous: nil, now: now)
        XCTAssertEqual(only, PremiumReport(until: nil, lifetime: false, kind: nil, startedAt: nil, products: ["themes"]))
    }

    func testNothingActiveEndsAnEarlierPremiumNowAndNothingIsSentForANeverPayingUser() {
        let prev = PremiumReport(until: now.addingTimeInterval(10 * 86400), lifetime: false, kind: "paid", startedAt: nil, products: [])
        let r = PremiumReport.from([], lifetimeProducts: [], previous: prev, now: now)
        XCTAssertEqual(r, PremiumReport(until: now, lifetime: false, kind: "paid", startedAt: nil, products: []))
        XCTAssertNil(PremiumReport.from([], lifetimeProducts: [], previous: nil, now: now))
        // Already ended: stays as it is.
        let ended = PremiumReport(until: now.addingTimeInterval(-86400), lifetime: false, kind: "paid", startedAt: nil, products: [])
        XCTAssertEqual(PremiumReport.from([], lifetimeProducts: [], previous: ended, now: now), ended)
    }
}

/// A transport that really suspends, so calls interleave on the actor like on a network.
final class SlowTransport: HTTPTransport, @unchecked Sendable {
    let inner = FakeTransport()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: 20_000_000)
        return try await inner.send(request)
    }
}

final class ConcurrencyTests: XCTestCase {
    func engine(_ t: HTTPTransport, _ s: MemoryStore) -> Engine {
        Engine(appKey: "tta_ABCDEFGHIJKLMNOPQRSTUVWX", baseURL: URL(string: "https://mailer.example.com")!, linkKey: "redirectUrl",
               transport: t, store: s, deviceInfo: { DeviceInfo(language: "cs", timeZone: nil, appVersion: nil, osVersion: nil) }, retry: false)
    }

    func testTagsAddedDuringARunningSyncAreSentWhenItEnds() async {
        let t = SlowTransport(), s = MemoryStore()
        let e = engine(t, s)
        async let first = e.sync()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await e.addTags(["x"])
        _ = await first
        try? await Task.sleep(nanoseconds: 100_000_000)
        let pending = await e.pendingTagCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(t.inner.sent.filter { $0.path.hasSuffix("/tags") }.count, 1)
    }

    func testTwoFlushesAtOnceSendEachChangeOnceAndInOrder() async {
        let t = SlowTransport(), s = MemoryStore()
        let e = engine(t, s)
        _ = await e.sync()
        async let a: Void = e.addTags(["x"])
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let b: Void = e.removeTags(["x"])
        _ = await (a, b)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let tags = t.inner.sent.filter { $0.path.hasSuffix("/tags") }
        XCTAssertEqual(tags.map { ($0.json?["add"] as? [String]) ?? [] }, [["x"], []])
        XCTAssertEqual(tags.last?.json?["remove"] as? [String], ["x"])
    }

    func testAResetDuringAFlushDoesNotCarryTheOldPremiumOver() async throws {
        let t = SlowTransport(), s = MemoryStore()
        let e = engine(t, s)
        _ = await e.sync()
        let r = PremiumReport(until: Date().addingTimeInterval(86400), lifetime: false, kind: "paid", startedAt: nil, products: nil)
        async let p: Void = e.setPremium(r)
        try? await Task.sleep(nanoseconds: 5_000_000)
        try await e.reset()
        _ = await p
        let sent = await e.sentPremium
        XCTAssertNil(sent, "the new installation has sent nothing")
    }
}
