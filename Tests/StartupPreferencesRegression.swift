import Foundation

// This executable never links the production keychain backend.
enum Keychain {
    static func warm() throws {}
    static func get(_ key: String) throws -> String? { nil }
    static func set(_ key: String, _ value: String) -> Bool { false }
    static func translationAPIKey() throws -> String? { nil }
    static func setTranslationAPIKey(_ value: String) -> Bool { false }
}

@main struct StartupPreferencesRegression {
    @MainActor static func main() throws {
        try AppSupport.assertProcessSupportIsIsolated()
        let mode = CommandLine.arguments[1]
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let legacy = try PropertyListSerialization.propertyList(from: fixture, format: nil) as! [String: Any]
        if mode == "helper-startup" {
            precondition(Bundle.main.bundleIdentifier == "one.yic.pigi")
            UserDefaults.standard.setVolatileDomain(legacy, forName: UserDefaults.argumentDomain)
            AppPreferences.configure()
            precondition(ProtonNetworkSettings.current().mode == .direct)
        } else if mode == "startup" {
            precondition(Bundle.main.bundleIdentifier == "one.yic.pigi")
            // No real preference daemon or persistent domain access is allowed.
            // The App still injects the real Foundation .standard instance.
            UserDefaults.standard.setVolatileDomain(legacy, forName: UserDefaults.argumentDomain)
            // Exactly the host bootstrap used by PigiApp.init, before sync/UI.
            try AppPreferences.prepare()
            precondition(CorePreferences.defaults === UserDefaults.standard)
            precondition(TranslationConfigStore().load().model == "legacy-model")
            precondition(TranslationPrivacySettings().isEnabled(accountID: "legacy@example.test"))
            precondition(ProtonNetworkSettings.current().mode == .direct)
            let emails = try AccountConfiguration.shared.emails(kind: "gmail")
            let clientID = try AccountConfiguration.shared.gmailClientID()
            precondition(emails == ["legacy@example.test"])
            precondition(clientID == "synthetic-client-id")
            precondition(UserDefaults.standard.stringArray(forKey: "gmailAccounts") == ["Legacy@Example.test"])
            // Replacing an injected host does not initialize the CLI fallback.
            let replacement = UserDefaults(suiteName: "startup.synthetic.override")!
            CorePreferences.defaults = replacement
            precondition(CorePreferences.defaults === replacement)
            CorePreferences.defaults = UserDefaults.standard
        } else if mode == "standalone" {
            precondition(Bundle.main.bundleIdentifier != "one.yic.pigi")
            CorePreferences.defaults.setVolatileDomain(legacy, forName: UserDefaults.argumentDomain)
            precondition(TranslationConfigStore().load().model == "legacy-model")
            precondition(ProtonNetworkSettings.current().mode == .direct)
            let clientID = try AccountConfiguration.shared.gmailClientID()
            precondition(clientID == "synthetic-client-id")
        } else { preconditionFailure("Unknown regression phase") }
        print("PASS: \(mode), bundle=\(Bundle.main.bundleIdentifier ?? "unbundled")")
    }
}
