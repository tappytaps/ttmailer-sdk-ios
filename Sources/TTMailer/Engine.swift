import Foundation

/// The installation state the app has set (kept between launches).
struct Desired: Codable, Equatable {
    var pushToken: String?
    var pushEnabled: Bool?
    /// Set by the app: true once setUserId was called (then userId nil = signed out, sent as null).
    var userIdSet = false
    var userId: String?
    /// The app's own language (TTM-584); nil = the system's.
    var language: String?
    /// TTM-588: false = the app turned activity reporting off (nil = on, the default).
    var trackActivity: Bool?
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
        static let tags = "pendingTags"
        static let premium = "pendingPremium"
        static let sentPremium = "sentPremium"
    }
    /// Tags per request (the server takes 20 in each list).
    static let tagsPerCall = 20
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
    /// Tag changes not sent yet: tag → true (add) / false (remove); the last change of a tag wins.
    private var pendingTags: [String: Bool]
    private var pendingPremium: PremiumReport?
    private var flushing = false
    private var flushAgain = false
    /// A flush found the installation being sent: it flushes when that sync ends.
    private var flushAfterSync = false

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
        pendingTags = store.data(forKey: Key.tags).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
        pendingPremium = store.data(forKey: Key.premium).flatMap { try? JSONDecoder().decode(PremiumReport.self, from: $0) }
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

    func setActivityTracking(_ enabled: Bool) async { await change { $0.trackActivity = enabled ? nil : false } }

    func setLanguage(_ language: String?) async {
        let l = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        await change { $0.language = (l?.isEmpty ?? true) ? nil : l }
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
        if let v = desired.language ?? info.language { b["language"] = v }
        if let v = info.timeZone { b["timeZone"] = v }
        if let v = info.appVersion { b["appVersion"] = v }
        if let v = info.osVersion { b["osVersion"] = v }
        b["sdkVersion"] = TTMailer.sdkVersion
        if let v = desired.pushToken { b["pushToken"] = v }
        if let v = desired.pushEnabled { b["pushEnabled"] = v }
        if desired.userIdSet { b["userId"] = desired.userId ?? NSNull() }
        if desired.trackActivity == false { b["trackActivity"] = false }
        return (try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Sends the installation when it changed since the last success, or a day passed. True when TTMailer has it.
    @discardableResult
    func sync() async -> Bool {
        if syncing { dirty = true; return false }
        syncing = true
        var ok = false
        repeat {
            dirty = false
            ok = await syncOnce()
        } while dirty && ok
        syncing = false
        if ok && flushAfterSync {
            flushAfterSync = false
            Task { await self.flushChanges() }
        }
        return ok
    }

    private func syncOnce() async -> Bool {
        let b = body()
        let t = now()
        // A key TTMailer does not know (rotated, disabled, a typo): tried again after a day, not on every call.
        if let dead = date(Key.deadKeyAt), t.timeIntervalSince(dead) < Self.resendAfter { return false }
        // Unchanged: sent again once a day ("last active in the app"; with activity reporting off it only keeps the
        // installation alive, TTM-588).
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
        await flushChanges()
    }

    // MARK: - Tags and premium (TTM-584, TTM-585)

    var pendingTagCount: Int { pendingTags.count }

    func addTags(_ tags: [String]) async { await changeTags(tags, add: true) }
    func removeTags(_ tags: [String]) async { await changeTags(tags, add: false) }

    private func changeTags(_ tags: [String], add: Bool) async {
        // What TTMailer takes (a-z 0-9 _ -, 40 at most): one bad tag must not lose the others of its request.
        let clean = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil }
        guard !clean.isEmpty else { return }
        for t in clean { pendingTags[t] = add }
        saveTags()
        await flushChanges()
    }

    /// The premium the app or the store reading reports; sent once, again only when it changes.
    func setPremium(_ report: PremiumReport) async {
        if pendingPremium == nil, report == sentPremium { return }
        pendingPremium = report
        store.set(try? JSONEncoder().encode(report), forKey: Key.premium)
        await flushChanges()
    }

    /// What the store says now (automatic purchases): a report when it differs from the last one sent.
    func storeEntitlements(_ entitlements: [Entitlement], lifetimeProducts: Set<String>?) async {
        guard let r = PremiumReport.from(entitlements, lifetimeProducts: lifetimeProducts, previous: pendingPremium ?? sentPremium, now: now()) else { return }
        await setPremium(r)
    }

    var sentPremium: PremiumReport? { store.data(forKey: Key.sentPremium).flatMap { try? JSONDecoder().decode(PremiumReport.self, from: $0) } }

    /// Sends waiting tag changes and the premium, after the installation (TTMailer needs it to know the contact).
    /// One flush at a time: a change made during it is sent by the same flush, after what is in flight (order kept).
    func flushChanges() async {
        guard !pendingTags.isEmpty || pendingPremium != nil else { return }
        if flushing { flushAgain = true; return }
        flushing = true
        defer { flushing = false }
        repeat {
            flushAgain = false
            guard await flushOnce() else { return }
        } while flushAgain
    }

    private func flushOnce() async -> Bool {
        guard !pendingTags.isEmpty || pendingPremium != nil else { return true }
        if syncing { flushAfterSync = true; return false }
        guard await sync() else { return false }
        // A reset or erasure meanwhile starts a new installation: nothing of the old one is carried over.
        let id = installationId
        while !pendingTags.isEmpty {
            let add = pendingTags.filter { $0.value }.keys.sorted().prefix(Self.tagsPerCall)
            let remove = pendingTags.filter { !$0.value }.keys.sorted().prefix(Self.tagsPerCall)
            let body = try? JSONSerialization.data(withJSONObject: ["add": Array(add), "remove": Array(remove)], options: [.sortedKeys])
            let r = await request("POST", "/sdk/v1/installations/\(id)/tags", body: body)
            guard installationId == id, handled(r) else { return false }
            // Only what was sent: a change made meanwhile stays.
            for t in add where pendingTags[t] == true { pendingTags[t] = nil }
            for t in remove where pendingTags[t] == false { pendingTags[t] = nil }
            saveTags()
        }
        if let p = pendingPremium {
            let body = try? JSONSerialization.data(withJSONObject: p.json, options: [.sortedKeys])
            let r = await request("POST", "/sdk/v1/installations/\(id)/premium", body: body)
            guard installationId == id, handled(r) else { return false }
            if case .success(let (status, _)) = r, (200..<300).contains(status) { store.set(try? JSONEncoder().encode(p), forKey: Key.sentPremium) }
            if pendingPremium == p { pendingPremium = nil; store.set(nil, forKey: Key.premium) }
        }
        return true
    }

    /// True when the change is done with: sent, or refused for good (a 4xx). False: kept for later (network, 5xx,
    /// 408/429, or TTMailer does not know the installation: it is sent again first).
    private func handled(_ r: Result<(Int, Data), Error>) -> Bool {
        guard case .success(let (status, body)) = r else { scheduleRetry(); return false }
        if (200..<300).contains(status) { return true }
        let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
        if status == 409, code == "unknown_installation" { store.set(nil, forKey: Key.lastBody); scheduleRetry(); return false }
        if status >= 500 || status == 408 || status == 429 { scheduleRetry(); return false }
        return true
    }

    private func saveTags() { store.set(pendingTags.isEmpty ? nil : try? JSONEncoder().encode(pendingTags), forKey: Key.tags) }

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
        if let l = language ?? desired.language ?? deviceInfo().language { b["language"] = l }
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
        pendingTags = [:]; pendingPremium = nil
        for k in [Key.desired, Key.lastBody, Key.lastAt, Key.deadKeyAt, Key.tags, Key.premium, Key.sentPremium] { store.set(nil, forKey: k) }
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
