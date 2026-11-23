import Foundation

/// The installation state the app has set (kept between launches).
struct Desired: Codable, Equatable {
    var pushToken: String?
    var pushEnabled: Bool?
    /// Set by the app: true once setUserId was called (then userId nil = signed out, sent as null).
    var userIdSet = false
    var userId: String?
}

struct PendingOpen: Codable, Equatable {
    let token: String
    let at: String
}

/// The SDK's work, one call at a time: the installation sync, open reports and the awaited calls.
actor Engine {
    private enum Key {
        static let installation = "installationId"
        static let desired = "desired"
        static let lastBody = "lastSentBody"
        static let lastAt = "lastSentAt"
        static let deadKeyAt = "deadKeyAt"
        static let opens = "pendingOpens"
    }
    /// An unchanged installation is still sent once a day (the contact's "last active in the app").
    static let resendAfter: TimeInterval = 24 * 3600
    static let maxPendingOpens = 100

    let appKey: String
    let baseURL: URL
    let linkKey: String
    private let transport: HTTPTransport
    private let store: KeyValueStore
    private let deviceInfo: @Sendable () -> DeviceInfo
    private let now: @Sendable () -> Date
    private let retryEnabled: Bool
    private(set) var installationId: String
    private var desired: Desired
    private var syncing = false
    private var dirty = false
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 30

    init(appKey: String, baseURL: URL, linkKey: String, transport: HTTPTransport, store: KeyValueStore,
         deviceInfo: @escaping @Sendable () -> DeviceInfo, now: @escaping @Sendable () -> Date = { Date() }, retry: Bool = true) {
        self.appKey = appKey; self.baseURL = baseURL; self.linkKey = linkKey
        self.transport = transport; self.store = store; self.deviceInfo = deviceInfo; self.now = now; self.retryEnabled = retry
        if let d = store.data(forKey: Key.installation), let id = String(data: d, encoding: .utf8), !id.isEmpty {
            installationId = id
        } else {
            installationId = UUID().uuidString.lowercased()
            store.set(Data(installationId.utf8), forKey: Key.installation)
        }
        desired = store.data(forKey: Key.desired).flatMap { try? JSONDecoder().decode(Desired.self, from: $0) } ?? Desired()
    }

    var pendingOpens: Int { loadOpens().count }

    // MARK: - The installation

    func setPushToken(_ token: Data) async { await setPushToken(token.map { String(format: "%02x", $0) }.joined()) }

    func setPushToken(_ token: String) async {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await change { $0.pushToken = t }
    }

    func setPushEnabled(_ enabled: Bool) async { await change { $0.pushEnabled = enabled } }

    func setUserId(_ userId: String?) async {
        let id = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        await change { $0.userIdSet = true; $0.userId = (id?.isEmpty ?? true) ? nil : id }
    }

    private func change(_ f: (inout Desired) -> Void) async {
        var d = desired
        f(&d)
        guard d != desired else { return }
        desired = d
        store.set(try? JSONEncoder().encode(d), forKey: Key.desired)
        _ = await sync()
    }

    /// The body of the next PUT: the app's state plus the device info.
    private func body() -> Data {
        let info = deviceInfo()
        var b: [String: Any] = [:]
        if let v = info.language { b["language"] = v }
        if let v = info.timeZone { b["timeZone"] = v }
        if let v = info.appVersion { b["appVersion"] = v }
        if let v = info.osVersion { b["osVersion"] = v }
        if let v = desired.pushToken { b["pushToken"] = v }
        if let v = desired.pushEnabled { b["pushEnabled"] = v }
        if desired.userIdSet { b["userId"] = desired.userId ?? NSNull() }
        return (try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Sends the installation when it changed since the last success, or a day passed. True when TTMailer has it.
    @discardableResult
    func sync() async -> Bool {
        if syncing { dirty = true; return false }
        syncing = true
        defer { syncing = false }
        var ok = false
        repeat {
            dirty = false
            ok = await syncOnce()
        } while dirty && ok
        return ok
    }

    private func syncOnce() async -> Bool {
        let b = body()
        let t = now()
        // A key TTMailer does not know (rotated, disabled, a typo): tried again after a day, not on every call.
        if let dead = date(Key.deadKeyAt), t.timeIntervalSince(dead) < Self.resendAfter { return false }
        if store.data(forKey: Key.lastBody) == b, let at = date(Key.lastAt), t.timeIntervalSince(at) < Self.resendAfter { return true }
        let id = installationId
        switch await request("PUT", "/sdk/v1/installations/\(id)", body: b) {
        case .success(let (status, _)) where (200..<300).contains(status):
            store.set(b, forKey: Key.lastBody)
            setDate(t, Key.lastAt)
            retryDelay = 30
            return true
        case .success(let (status, _)) where status == 404:
            setDate(t, Key.deadKeyAt)
            return false
        case .success(let (status, _)) where status == 400:
            // The body itself is wrong: sending it again would not help; the next change or day tries again.
            store.set(b, forKey: Key.lastBody)
            setDate(t, Key.lastAt)
            return false
        default:
            scheduleRetry()
            return false
        }
    }

    private func scheduleRetry() {
        guard retryEnabled, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 3600)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.retryNow()
        }
    }

    private func retryNow() async {
        retryTask = nil
        _ = await sync()
        await flushOpens()
    }

    // MARK: - Push opens

    /// The link of the push (data key `linkKey`) and an open report queued when the push carries `ttmToken`.
    func opened(_ userInfo: [AnyHashable: Any]) -> URL? {
        if let token = userInfo["ttmToken"] as? String, !token.isEmpty, token.count <= 256 {
            var opens = loadOpens()
            opens.append(PendingOpen(token: token, at: Self.iso(now())))
            saveOpens(Array(opens.suffix(Self.maxPendingOpens)))
        }
        guard let link = userInfo[linkKey] as? String, let url = URL(string: link), url.scheme != nil else { return nil }
        return url
    }

    /// Sends the queued open reports: dropped on 2xx and on 4xx (except 408 and 429), kept for later otherwise.
    func flushOpens() async {
        var opens = loadOpens()
        while let first = opens.first {
            let body = (try? JSONSerialization.data(withJSONObject: ["t": first.token, "at": first.at])) ?? Data()
            let r = await request("POST", "/p/open", body: body, key: false)
            if case .success(let (status, _)) = r, status < 500, status != 408, status != 429 {
                opens.removeFirst()
                saveOpens(opens)
            } else {
                scheduleRetry()
                return
            }
        }
    }

    private func loadOpens() -> [PendingOpen] {
        store.data(forKey: Key.opens).flatMap { try? JSONDecoder().decode([PendingOpen].self, from: $0) } ?? []
    }
    private func saveOpens(_ opens: [PendingOpen]) { store.set(opens.isEmpty ? nil : try? JSONEncoder().encode(opens), forKey: Key.opens) }

    // MARK: - Awaited calls

    /// Signs the address up through the app's form; TTMailer sends a confirmation e-mail. Returns whether it confirms.
    func subscribe(email: String, language: String?) async throws -> Bool {
        // The installation first, so the confirmed address joins this installation's contact.
        _ = await sync()
        var b: [String: Any] = ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let language { b["language"] = language } else if let l = deviceInfo().language { b["language"] = l }
        let data = try JSONSerialization.data(withJSONObject: b)
        let (status, body) = try check(await request("POST", "/sdk/v1/installations/\(installationId)/subscribe", body: data))
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        _ = status
        return json?["confirm"] as? Bool ?? true
    }

    /// Removes this installation's device (and its anonymous contact) and starts a new installation.
    func reset() async throws {
        _ = try check(await request("DELETE", "/sdk/v1/installations/\(installationId)", body: nil))
        newInstallation()
    }

    /// Erases the installation's contact in TTMailer (the user deleted their account) and starts a new installation.
    func deleteContact() async throws {
        _ = try check(await request("DELETE", "/sdk/v1/installations/\(installationId)/contact", body: nil))
        newInstallation()
    }

    private func newInstallation() {
        installationId = UUID().uuidString.lowercased()
        store.set(Data(installationId.utf8), forKey: Key.installation)
        desired = Desired()
        for k in [Key.desired, Key.lastBody, Key.lastAt, Key.deadKeyAt] { store.set(nil, forKey: k) }
    }

    private func check(_ r: Result<(Int, Data), Error>) throws -> (Int, Data) {
        switch r {
        case .failure: throw TTMailerError.network
        case .success(let (status, body)):
            if (200..<300).contains(status) { return (status, body) }
            let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
            switch (status, code) {
            case (400, "invalid_email"): throw TTMailerError.invalidEmail
            case (409, "no_form"): throw TTMailerError.noForm
            case (409, "form_without_confirmation"): throw TTMailerError.formWithoutConfirmation
            case (429, _): throw TTMailerError.rateLimited
            default: throw TTMailerError.server(status: status, code: code)
            }
        }
    }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, body: Data?, key: Bool = true) async -> Result<(Int, Data), Error> {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 20
        if key { r.setValue(appKey, forHTTPHeaderField: "X-TTMailer-App-Key") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await transport.send(r)
            return .success((response.statusCode, data))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Helpers

    private func date(_ key: String) -> Date? {
        store.data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }
    private func setDate(_ d: Date, _ key: String) { store.set(Data(String(d.timeIntervalSince1970).utf8), forKey: key) }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
