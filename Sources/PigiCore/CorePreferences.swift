import Foundation

/// Explicit app preference domain for settings outside account configuration.
/// Hosts may inject an isolated domain; the core never uses process defaults.
public enum CorePreferences {
    private static var injectedDefaults: UserDefaults?

    // A setter must not initialize the standalone suite. Foundation rejects a
    // suite named after Bundle.main, including while the App is injecting its
    // own preferences. Keep the CLI fallback lazy and separate from injection.
    public static var defaults: UserDefaults {
        get { injectedDefaults ?? standaloneDefaults }
        set { injectedDefaults = newValue }
    }

    private static let standaloneDefaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: "one.yic.pigi") else {
            preconditionFailure("The App host must inject preferences before using PigiCore settings")
        }
        return defaults
    }()
}
