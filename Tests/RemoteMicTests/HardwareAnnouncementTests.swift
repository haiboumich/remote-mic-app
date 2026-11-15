import Foundation
import Testing
@testable import RemoteMic

@Suite("Hardware announcements")
struct HardwareAnnouncementTests {
    @Test func sourceIsAlwaysDisabledForOfflineBuilds() throws {
        #expect(HardwareAnnouncementSource.resolve() == OfflineRuntimePolicy.disabledExternalURL)
    }

    @Test func announcementUsesLanguageFallbackAndExpiry() throws {
        let data = Data(#"""
        {
          "id": "apple-siri-remote",
          "hardware": "Apple Siri Remote",
          "title": {"zh-Hans": "新增支持", "en": "Support added"},
          "message": {"zh-Hans": "请安装 PKG", "en": "Install the PKG"},
          "downloadURL": "https://download.sayall.app/mac/releases/vX.Y.Z/SayAll-X.Y.Z-BUILD-AppleSilicon-install.pkg",
          "expiresAt": null
        }
        """#.utf8)
        let announcement = try JSONDecoder().decode(HardwareAnnouncement.self, from: data)

        #expect(announcement.title(for: Locale(identifier: "zh-Hans")) == "新增支持")
        #expect(announcement.message(for: Locale(identifier: "en-US")) == "Install the PKG")
        #expect(!announcement.isExpired)

        let expired = HardwareAnnouncement(
            id: "expired",
            hardware: "Expired hardware",
            title: [:],
            message: [:],
            downloadURL: try #require(URL(string: "https://download.sayall.app/expired.pkg")),
            expiresAt: Date(timeIntervalSince1970: 0)
        )
        #expect(expired.isExpired)
    }
}
