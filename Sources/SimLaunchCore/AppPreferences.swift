import Foundation

public enum AppPreferences {
    public static let bundleIdentifier = "dev.ekko.simlaunch"

    /// The previous identifier is intentionally retained only as a migration source.
    public static func migrateIfNeeded(
        in defaults: UserDefaults = .standard,
        legacyDomain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "dev.simlaunch.app")
    ) {
        let marker = "didMigrateLegacyPreferences"
        guard !defaults.bool(forKey: marker) else { return }
        for key in ["configuration", "recentDeviceIDs", "appLanguage"] {
            if defaults.object(forKey: key) == nil, let value = legacyDomain?[key] {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
