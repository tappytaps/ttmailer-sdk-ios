import Foundation

/// Why a call that the app awaits (subscribe, reset, deleteContact) failed.
public enum TTMailerError: Error, Sendable {
    /// `TTMailer.configure(appKey:)` was not called.
    case notConfigured
    /// The address is not a valid e-mail address.
    case invalidEmail
    /// The app has no sign-up form in TTMailer (or it is disabled).
    case noForm
    /// The app's form does not confirm addresses (the SDK always needs confirmation).
    case formWithoutConfirmation
    /// Too many requests from this network; try later.
    case rateLimited
    /// No connection, or the request timed out.
    case network
    /// Any other answer of the server.
    case server(status: Int, code: String?)
}
