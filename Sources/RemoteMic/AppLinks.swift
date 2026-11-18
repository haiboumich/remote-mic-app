import Foundation

enum AppLinks {
    // Offline-only builds intentionally never expose a routable web URL.
    static let githubRepository = OfflineRuntimePolicy.disabledExternalURL
    static let chineseWebsite = OfflineRuntimePolicy.disabledExternalURL
    static let englishWebsite = OfflineRuntimePolicy.disabledExternalURL
    static let chineseIOSAppStore = OfflineRuntimePolicy.disabledExternalURL
    static let englishIOSAppStore = OfflineRuntimePolicy.disabledExternalURL
    static let feedback = OfflineRuntimePolicy.disabledExternalURL
    static let doubaoInputMethod = URL(
        string: "https://shurufa.doubao.com/?utm_source=sayall.app"
    )!
    static let vokieWebsite = URL(string: "https://vokie.com/?utm_source=sayall.app")!

    static func iOSAppStore(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseIOSAppStore
            : englishIOSAppStore
    }

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }
}
