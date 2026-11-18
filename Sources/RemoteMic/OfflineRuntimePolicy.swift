import Foundation

/// Runtime network boundary for the self-built offline-only App.
///
/// This is deliberately a compile-time product decision, not a preference: a
/// user must never need to discover and turn off a network feature after the
/// App has launched.
enum OfflineRuntimePolicy {
    static let externalLinksEnabled = false
    static let updateFeaturesEnabled = false
    static let onlineCompanionFeaturesEnabled = false
    static let hardwareAnnouncementsEnabled = false
    static let diagnosticUploadsEnabled = false
    static let toolDownloadLinksEnabled = true

    /// Routable URLs are limited to explicit user actions such as downloading a
    /// third-party input tool or opening the exact source revision. The App
    /// never probes or preloads them.
    static let sourceCommitLinkEnabled = true

    /// A non-routable custom scheme used only to keep legacy UI contracts type
    /// safe while their external destinations are removed. It cannot result in
    /// DNS, HTTP(S), or an App Store request.
    static let disabledExternalURL = URL(string: "sayall-offline://disabled")!

    static func isAllowedLocalIPC(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "ws",
              let host = url.host?.lowercased()
        else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
