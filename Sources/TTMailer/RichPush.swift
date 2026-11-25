import Foundation

/// What a tap on a TTMailer push does (`ttmAction` in the push data, TTM-624). Absent or unknown = `app`.
enum PushAction: String, Equatable {
    /// The link goes to the app (a deep link or URL), as before 0.4.0.
    case app
    /// The system browser.
    case browser
    /// The system in-app browser (SFSafariViewController); store links go to the store.
    case inapp
    /// An in-app message written in TTMailer, shown in a full-screen web view.
    case message
}

/// What `TTMailer.handle` does with a tap.
enum TapStep: Equatable {
    /// Hand the link (or nil) back to the app.
    case returnLink(URL?)
    /// Open the URL through the system (the browser, or the app that handles it).
    case openSystem(URL)
    /// An App Store / Google Play link: the store (a system open).
    case openStore(URL)
    /// SFSafariViewController.
    case openInAppBrowser(URL)
    /// The full-screen message web view.
    case showMessage(URL)
}

/// A TTMailer push as the SDK reads it.
struct RichPush: Equatable {
    /// The open token (`ttmToken`).
    let token: String?
    /// The link under the project's link key (what `opened` returns).
    let link: URL?
    let action: PushAction
    /// `ttmUrl`: the raw target (browser / inapp) or the message URL; falls back to the link.
    let target: URL?

    init(_ userInfo: [AnyHashable: Any], linkKey: String) {
        token = (userInfo["ttmToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        link = Self.url(userInfo[linkKey])
        action = (userInfo["ttmAction"] as? String).flatMap { PushAction(rawValue: $0.lowercased()) } ?? .app
        target = Self.url(userInfo["ttmUrl"]) ?? link
    }

    /// What a tap does with this push.
    var step: TapStep {
        switch action {
        case .app:
            return .returnLink(link)
        case .browser:
            guard let t = target else { return .returnLink(link) }
            return StoreURL.isStore(t) ? .openStore(t) : .openSystem(t)
        case .inapp:
            guard let t = target else { return .returnLink(link) }
            if StoreURL.isStore(t) { return .openStore(t) }
            return StoreURL.isWeb(t) ? .openInAppBrowser(t) : .openSystem(t)
        case .message:
            guard let t = target, StoreURL.isWeb(t) else { return .returnLink(link) }
            return .showMessage(t)
        }
    }

    static func url(_ value: Any?) -> URL? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let url = URL(string: s), url.scheme != nil else { return nil }
        return url
    }
}

/// App Store and Google Play links (they always open the store).
enum StoreURL {
    static let storeHosts: Set<String> = ["apps.apple.com", "itunes.apple.com"]
    static let storeSchemes: Set<String> = ["itms-apps", "itms-appss", "market"]

    /// Hosts `apps.apple.com`, `itunes.apple.com`, `play.google.com` (path `/store…`); schemes `itms-apps`,
    /// `itms-appss`, `market`.
    static func isStore(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if storeSchemes.contains(scheme) { return true }
        guard scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return false }
        if storeHosts.contains(host) { return true }
        return host == "play.google.com" && url.path.hasPrefix("/store")
    }

    /// An http(s) URL with a host (what SFSafariViewController accepts).
    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }
}

/// What the message web view does with a navigation.
enum MessageNavigation: Equatable {
    /// Load it in the web view (TTMailer pages and their click redirects).
    case allow
    /// Drop it.
    case cancel
    /// `ttmailer://close`: dismiss the message.
    case close
    /// The store (a system open), the message stays.
    case store(URL)
    /// The in-app browser over the message.
    case browser(URL)
    /// Any other scheme: dismiss, then the app's `onDeepLink` (or a system open).
    case deepLink(URL)

    /// - Parameters:
    ///   - url: the request's URL (a link click or the target of a redirect).
    ///   - mainFrame: false for a navigation inside a frame of the page (it never leaves the web view).
    ///   - ttmailerHosts: the TTMailer host(s), lowercased.
    static func decide(_ url: URL, mainFrame: Bool, ttmailerHosts: Set<String>) -> MessageNavigation {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "ttmailer" {
            return url.host?.lowercased() == "close" ? .close : .cancel
        }
        if scheme == "about" { return .allow }
        let web = StoreURL.isWeb(url)
        if web, let host = url.host?.lowercased(), ttmailerHosts.contains(host) { return .allow }
        if !mainFrame { return web ? .allow : .cancel }
        if StoreURL.isStore(url) { return .store(url) }
        if web { return .browser(url) }
        if scheme.isEmpty || scheme == "http" || scheme == "https" || scheme == "data" || scheme == "blob" || scheme == "javascript" {
            return .cancel
        }
        return .deepLink(url)
    }
}

/// The few texts of the message screen, in the app's language (English when the SDK does not have it).
struct MessageStrings: Equatable {
    let error: String
    let tryAgain: String
    let close: String

    static func forLanguage(_ language: String?) -> MessageStrings {
        let code = (language ?? "en").lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        switch code {
        case "cs": return MessageStrings(error: "Zprávu se nepodařilo načíst.", tryAgain: "Zkusit znovu", close: "Zavřít")
        case "sk": return MessageStrings(error: "Správu sa nepodarilo načítať.", tryAgain: "Skúsiť znova", close: "Zavrieť")
        case "de": return MessageStrings(error: "Die Nachricht konnte nicht geladen werden.", tryAgain: "Erneut versuchen", close: "Schließen")
        case "es": return MessageStrings(error: "No se pudo cargar el mensaje.", tryAgain: "Reintentar", close: "Cerrar")
        case "fr": return MessageStrings(error: "Impossible de charger le message.", tryAgain: "Réessayer", close: "Fermer")
        case "it": return MessageStrings(error: "Impossibile caricare il messaggio.", tryAgain: "Riprova", close: "Chiudi")
        case "pl": return MessageStrings(error: "Nie udało się wczytać wiadomości.", tryAgain: "Spróbuj ponownie", close: "Zamknij")
        case "pt": return MessageStrings(error: "Não foi possível carregar a mensagem.", tryAgain: "Tentar novamente", close: "Fechar")
        default: return MessageStrings(error: "The message couldn't be loaded.", tryAgain: "Try again", close: "Close")
        }
    }
}
