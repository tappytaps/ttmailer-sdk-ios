import Foundation

/// What the SDK tells TTMailer about the device on every sync.
public struct DeviceInfo: Sendable, Equatable {
    public var language: String?
    public var timeZone: String?
    public var appVersion: String?
    public var osVersion: String?

    public init(language: String?, timeZone: String?, appVersion: String?, osVersion: String?) {
        self.language = language; self.timeZone = timeZone; self.appVersion = appVersion; self.osVersion = osVersion
    }

    /// The device's preferred language, time zone, the app's version (CFBundleShortVersionString) and the OS version.
    public static func current() -> DeviceInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return DeviceInfo(
            language: Locale.preferredLanguages.first,
            timeZone: TimeZone.current.identifier,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            osVersion: os
        )
    }
}
