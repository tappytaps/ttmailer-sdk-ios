import Foundation

/// Where the SDK keeps its state between launches (UserDefaults in the app, memory in tests).
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(suiteName: String = "com.tappytaps.ttmailer.sdk") { defaults = UserDefaults(suiteName: suiteName) ?? .standard }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
