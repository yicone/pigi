import Foundation

/// Explicit app preference domain for settings outside account configuration.
/// Hosts may inject an isolated domain; the core never uses process defaults.
public enum CorePreferences {
    public static var defaults: UserDefaults = UserDefaults(suiteName: "one.yic.pigi")!
}
