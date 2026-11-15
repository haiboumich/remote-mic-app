import Foundation
import Testing
@testable import RemoteMic

@Suite("Offline-only runtime boundary")
struct OfflineRuntimePolicyTests {
    @Test func externalDestinationsAreNotRoutable() {
        #expect(!OfflineRuntimePolicy.externalLinksEnabled)
        #expect(AppLinks.githubRepository == OfflineRuntimePolicy.disabledExternalURL)
        #expect(AppLinks.website(for: Locale(identifier: "en")) == OfflineRuntimePolicy.disabledExternalURL)
        #expect(OfflineRuntimePolicy.disabledExternalURL.scheme == "sayall-offline")
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
