import Foundation
import Testing
@testable import RemoteMic

struct FeedbackLinkTests {
    @Test func feedbackIsUnavailableInOfflineBuild() throws {
        let components = try #require(URLComponents(
            url: AppLinks.feedback,
            resolvingAgainstBaseURL: false
        ))

        #expect(components.url == OfflineRuntimePolicy.disabledExternalURL)
        #expect(components.scheme != "https")
        #expect(components.queryItems == nil)
    }

    @Test func aboutPageOwnsFeedbackWithoutKeepingTheStatusMenuEntry() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RemoteMic/RemoteMicApp.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RemoteMic/SettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(!appSource.contains("#selector(openFeedback)"))
        #expect(!appSource.contains("@objc private func openFeedback()"))
        #expect(!settingsSource.contains("Link(destination: AppLinks.feedback)"))
        #expect(!settingsSource.contains("about.support.feedback_action"))
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
