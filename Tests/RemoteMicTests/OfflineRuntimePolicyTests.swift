import Foundation
import Testing
@testable import RemoteMic

@Suite("Offline-only runtime boundary")
struct OfflineRuntimePolicyTests {
    @Test func externalDestinationsAreNotRoutable() {
        #expect(!OfflineRuntimePolicy.externalLinksEnabled)
        #expect(!OfflineRuntimePolicy.updateFeaturesEnabled)
        #expect(!OfflineRuntimePolicy.onlineCompanionFeaturesEnabled)
        #expect(!OfflineRuntimePolicy.hardwareAnnouncementsEnabled)
        #expect(!OfflineRuntimePolicy.diagnosticUploadsEnabled)
        #expect(OfflineRuntimePolicy.toolDownloadLinksEnabled)
        #expect(OfflineRuntimePolicy.sourceCommitLinkEnabled)
        #expect(AppLinks.githubRepository == OfflineRuntimePolicy.disabledExternalURL)
        #expect(AppLinks.website(for: Locale(identifier: "en")) == OfflineRuntimePolicy.disabledExternalURL)
        #expect(AppLinks.doubaoInputMethod.host == "shurufa.doubao.com")
        #expect(AppLinks.vokieWebsite.host == "vokie.com")
        #expect(OfflineRuntimePolicy.disabledExternalURL.scheme == "sayall-offline")
    }

    @Test func sourceCommitLinkUsesOnlyAValidatedEmbeddedRevision() throws {
        let commit = "a00fbaacf400aa527474b358f65ee840ee0cd5e8"
        let provenance = try #require(BuildProvenance.parse(commit))
        #expect(provenance.sourceCommit == commit)
        #expect(provenance.shortSourceCommit == "a00fbaac")
        #expect(provenance.sourceCommitURL?.absoluteString ==
            "https://github.com/haiboumich/remote-mic-app/commit/\(commit)")

        #expect(BuildProvenance.parse(nil) == nil)
        #expect(BuildProvenance.parse("a00fbaac") == nil)
        #expect(BuildProvenance.parse(String(repeating: "G", count: 40)) == nil)
        #expect(BuildProvenance.parse(commit + "\n") == nil)
    }

    @Test func onlineCompanionSourcesStayHidden() {
        let sources: [OnboardingControlSource] = [
            .xiaomiRemote, .chromecastRemote, .appleCompanion, .webRemote,
        ]
        #expect(OnboardingControlSourceVisibilityPolicy.visibleSources(sources) == [
            .xiaomiRemote, .chromecastRemote,
        ])
    }

    @Test func offlineUIHidesOnlineActionsAndRoutesAboutToProvenance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let onboardingSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains(
            "if OfflineRuntimePolicy.onlineCompanionFeaturesEnabled {\n                            phoneConnectionsPanel"
        ))
        #expect(settingsSource.contains("if OfflineRuntimePolicy.updateFeaturesEnabled"))
        #expect(settingsSource.contains("if OfflineRuntimePolicy.hardwareAnnouncementsEnabled"))
        #expect(settingsSource.contains("if OfflineRuntimePolicy.diagnosticUploadsEnabled"))
        #expect(settingsSource.contains("diagnostics.logs.offline_privacy"))
        #expect(settingsSource.contains("BuildProvenance.current()"))
        #expect(settingsSource.contains("Link(destination: destination)"))
        #expect(onboardingSource.contains(
            "if OfflineRuntimePolicy.toolDownloadLinksEnabled,\n               voiceToolAvailability[.doubao]"
        ))
        #expect(onboardingSource.contains(
            "if OfflineRuntimePolicy.toolDownloadLinksEnabled, tool == .vokie"
        ))
        #expect(appSource.contains(
            "@objc private func showAbout() {\n        showSettingsWindow(initialSection: .about)"
        ))
    }

    @Test func onlyLoopbackIPCAddressesAreAccepted() {
        #expect(OfflineRuntimePolicy.isAllowedLocalIPC(URL(string: "http://127.0.0.1:8080")!))
        #expect(OfflineRuntimePolicy.isAllowedLocalIPC(URL(string: "ws://localhost:8080")!))
        #expect(!OfflineRuntimePolicy.isAllowedLocalIPC(URL(string: "https://sayall.app")!))
        #expect(!OfflineRuntimePolicy.isAllowedLocalIPC(URL(string: "http://192.168.1.2")!))
    }

    @Test @MainActor func hardwareAnnouncementsDoNotCreateARequest() {
        let store = HardwareAnnouncementStore(logger: { _ in })
        store.refresh()
        #expect(store.announcements.isEmpty)
        #expect(!store.isLoading)
    }
}
