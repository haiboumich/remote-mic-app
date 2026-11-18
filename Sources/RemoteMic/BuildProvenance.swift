import Foundation

/// Auditable source identity embedded by `scripts/build-app.sh`.
///
/// Reading this value is entirely local. The URL is only handed to macOS after
/// the user explicitly clicks the commit link in About; no request is made while
/// rendering the page or starting the App.
struct BuildProvenance: Equatable {
    static let sourceCommitInfoKey = "SayAllSourceCommit"
    static let sourceRepositoryURL = URL(
        string: "https://github.com/haiboumich/remote-mic-app"
    )!

    let sourceCommit: String

    var shortSourceCommit: String {
        String(sourceCommit.prefix(8))
    }

    var sourceCommitURL: URL? {
        guard OfflineRuntimePolicy.sourceCommitLinkEnabled else { return nil }
        return Self.sourceRepositoryURL
            .appendingPathComponent("commit", isDirectory: false)
            .appendingPathComponent(sourceCommit, isDirectory: false)
    }

    static func current(bundle: Bundle = .main) -> Self? {
        parse(bundle.object(forInfoDictionaryKey: sourceCommitInfoKey) as? String)
    }

    static func parse(_ rawValue: String?) -> Self? {
        guard let rawValue,
              rawValue.range(
                of: #"^[0-9a-f]{40}$"#,
                options: .regularExpression
              ) != nil
        else { return nil }
        return Self(sourceCommit: rawValue)
    }
}
