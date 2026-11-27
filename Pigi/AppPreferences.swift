import Foundation
#if canImport(PigiCore)
import PigiCore
#endif

/// App-owned preference access stays outside PigiCore. Also exercised by the
/// isolated startup regression with the production Bundle identifier.
enum AppPreferences {
    static func configure() {
        CorePreferences.defaults = UserDefaults.standard
    }

    static func prepare() throws {
        configure()
        try AccountConfiguration.shared.migrateLegacy(defaults: UserDefaults.standard)
    }
}
