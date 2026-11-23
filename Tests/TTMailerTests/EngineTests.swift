import XCTest
@testable import TTMailer

/// A transport that records requests and answers from a queue (default 200 {"ok":true}).
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Sent { let method: String; let path: String; let json: [String: Any]?; let headers: [String: String] }
    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var answers: [Result<(Int, String), Error>] = []
    var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }
    func answer(_ code: Int, _ body: String = "{\"ok\":true}") { lock.lock(); answers.append(.success((code, body))); lock.unlock() }
    func fail() { lock.lock(); answers.append(.failure(URLError(.notConnectedToInternet))); lock.unlock() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let next: Result<(Int, String), Error> = lock.withLock {
            _sent.append(Sent(method: request.httpMethod ?? "GET", path: request.url!.path, json: json, headers: request.allHTTPHeaderFields ?? [:]))
            return answers.isEmpty ? .success((200, "{\"ok\":true}")) : answers.removeFirst()
        }
        switch next {
        case .failure(let e): throw e
        case .success(let (code, body)):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
}

final class EngineTests: XCTestCase {
    let key = "tta_ABCDEFGHIJKLMNOPQRSTUVWX"
    let info = DeviceInfo(language: "cs-CZ", timeZone: "Europe/Prague", appVersion: "3.2.1", osVersion: "18.1")
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func engine(_ t: FakeTransport, _ s: MemoryStore) -> Engine {
        Engine(appKey: key, baseURL: URL(string: "https://mailer.example.com")!, linkKey: "redirectUrl",
               transport: t, store: s, deviceInfo: { [info] in info }, now: { [unowned self] in self.now }, retry: false)
    }

    func testFirstSyncSendsTheInstallationWithTheKeyAndDeviceInfo() async throws {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        let ok = await e.sync()
        XCTAssertTrue(ok)
        let id = await e.installationId
        XCTAssertEqual(t.sent.count, 1)
        XCTAssertEqual(t.sent[0].method, "PUT")
        XCTAssertEqual(t.sent[0].path, "/sdk/v1/installations/\(id)")
        XCTAssertEqual(t.sent[0].headers["X-TTMailer-App-Key"], key)
        XCTAssertEqual(t.sent[0].json?["language"] as? String, "cs-CZ")
        XCTAssertEqual(t.sent[0].json?["timeZone"] as? String, "Europe/Prague")
        XCTAssertEqual(t.sent[0].json?["appVersion"] as? String, "3.2.1")
        XCTAssertEqual(t.sent[0].json?["osVersion"] as? String, "18.1")
        XCTAssertNil(t.sent[0].json?["pushToken"])
        XCTAssertNil(t.sent[0].json?["userId"], "userId not sent until the app sets it")
    }

    func testTheInstallationIdSurvivesARestart() async {
        let t = FakeTransport(), s = MemoryStore()
        let a = await engine(t, s).installationId
        let b = await engine(t, s).installationId
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 36)
    }

    func testNothingIsResentWhenNothingChangedWithinADay() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        _ = await e.sync()
        _ = await e.sync()
        XCTAssertEqual(t.sent.count, 1)
        now = now.addingTimeInterval(25 * 3600)
        _ = await e.sync()
        XCTAssertEqual(t.sent.count, 2, "once a day even unchanged (last active)")
    }

    func testTokenSwitchAndUserIdAreSentAndAPersistentChangeTriggersASync() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        await e.setPushToken(Data([0x0a, 0xbc, 0xff]))
        await e.setPushEnabled(true)
        await e.setUserId("acc-1")
        let last = t.sent.last!.json!
        XCTAssertEqual(last["pushToken"] as? String, "0abcff")
        XCTAssertEqual(last["pushEnabled"] as? Bool, true)
        XCTAssertEqual(last["userId"] as? String, "acc-1")
        // Signing out sends an explicit null.
        await e.setUserId(nil)
        XCTAssertTrue(t.sent.last!.json!["userId"] is NSNull)
        // A new engine (app restart) keeps the state.
        let again = engine(t, s)
        now = now.addingTimeInterval(25 * 3600)
        _ = await again.sync()
        XCTAssertEqual(t.sent.last!.json!["pushToken"] as? String, "0abcff")
        XCTAssertTrue(t.sent.last!.json!["userId"] is NSNull)
    }

    func testAFailedSyncIsRetriedNextTime() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        t.fail()
        let first = await e.sync()
        XCTAssertFalse(first)
        t.answer(503, "{}")
        let second = await e.sync()
        XCTAssertFalse(second)
        let third = await e.sync()
        XCTAssertTrue(third)
        XCTAssertEqual(t.sent.count, 3)
    }

    func testAKeyRejected404IsNotRetriedForeverButAfterADay() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        t.answer(404, "{\"error\":\"not_found\"}")
        _ = await e.sync()
        _ = await e.sync()
        XCTAssertEqual(t.sent.count, 1, "a dead key does not hammer the server")
    }

    func testOpenedReportsTheTokenAndReturnsTheLink() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        let url = await e.opened(["ttmToken": "abc.def", "redirectUrl": "https://bibino.com/x", "aps": ["alert": "hi"]])
        XCTAssertEqual(url?.absoluteString, "https://bibino.com/x")
        await e.flushOpens()
        let open = t.sent.first { $0.path == "/p/open" }
        XCTAssertEqual(open?.method, "POST")
        XCTAssertEqual(open?.json?["t"] as? String, "abc.def")
        XCTAssertNotNil(open?.json?["at"] as? String)
    }

    func testOpensWaitOfflineAndAreDroppedOnA4xx() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        t.fail()
        _ = await e.opened(["ttmToken": "a.b"])
        await e.flushOpens()
        var pending = await e.pendingOpens
        XCTAssertEqual(pending, 1)
        // Survives a restart.
        let again = engine(t, s)
        t.answer(204, "")
        await again.flushOpens()
        pending = await again.pendingOpens
        XCTAssertEqual(pending, 0)
        t.answer(400, "{}")
        _ = await again.opened(["ttmToken": "c.d"])
        await again.flushOpens()
        pending = await again.pendingOpens
        XCTAssertEqual(pending, 0, "a 4xx is never retried")
        XCTAssertEqual(t.sent.filter { $0.path == "/p/open" }.count, 3)
    }

    func testAPushWithoutTheTokenIsNotReported() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        let url = await e.opened(["redirectUrl": "notaurl with spaces"])
        XCTAssertNil(url)
        await e.flushOpens()
        XCTAssertTrue(t.sent.isEmpty)
    }

    func testSubscribeSyncsFirstThenSignsUp() async throws {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        t.answer(200)
        t.answer(200, "{\"ok\":true,\"confirm\":true}")
        let confirm = try await e.subscribe(email: "jana@example.com", language: "cs")
        XCTAssertTrue(confirm)
        let id = await e.installationId
        XCTAssertEqual(t.sent.map(\.method), ["PUT", "POST"])
        XCTAssertEqual(t.sent[1].path, "/sdk/v1/installations/\(id)/subscribe")
        XCTAssertEqual(t.sent[1].json?["email"] as? String, "jana@example.com")
        XCTAssertEqual(t.sent[1].json?["language"] as? String, "cs")
    }

    func testSubscribeErrors() async {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        _ = await e.sync()
        t.answer(400, "{\"error\":\"invalid_email\"}")
        do { _ = try await e.subscribe(email: "x", language: nil); XCTFail() } catch { XCTAssertEqual(error as? TTMailerError, .invalidEmail) }
        t.answer(409, "{\"error\":\"no_form\"}")
        do { _ = try await e.subscribe(email: "a@b.cz", language: nil); XCTFail() } catch { XCTAssertEqual(error as? TTMailerError, .noForm) }
        t.answer(429, "{\"error\":\"rate_limited\"}")
        do { _ = try await e.subscribe(email: "a@b.cz", language: nil); XCTFail() } catch { XCTAssertEqual(error as? TTMailerError, .rateLimited) }
        t.fail()
        do { _ = try await e.subscribe(email: "a@b.cz", language: nil); XCTFail() } catch { XCTAssertEqual(error as? TTMailerError, .network) }
    }

    func testResetDeletesTheInstallationAndStartsANewOne() async throws {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        await e.setPushToken("tok")
        let before = await e.installationId
        try await e.reset()
        XCTAssertEqual(t.sent.last!.method, "DELETE")
        XCTAssertEqual(t.sent.last!.path, "/sdk/v1/installations/\(before)")
        let after = await e.installationId
        XCTAssertNotEqual(before, after)
        // The token is not carried over (the app sends it again).
        _ = await e.sync()
        XCTAssertNil(t.sent.last!.json!["pushToken"])
    }

    func testDeleteContactErasesAndForgetsTheUser() async throws {
        let t = FakeTransport(), s = MemoryStore()
        let e = engine(t, s)
        await e.setUserId("acc-9")
        let id = await e.installationId
        try await e.deleteContact()
        XCTAssertEqual(t.sent.last!.method, "DELETE")
        XCTAssertEqual(t.sent.last!.path, "/sdk/v1/installations/\(id)/contact")
        let next = await e.installationId
        XCTAssertNotEqual(id, next)
    }
}

extension TTMailerError: Equatable {
    public static func == (a: TTMailerError, b: TTMailerError) -> Bool { String(describing: a) == String(describing: b) }
}
