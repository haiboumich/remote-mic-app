import Combine
import Foundation

struct HardwareAnnouncement: Decodable, Equatable, Identifiable {
    let id: String
    let hardware: String
    let title: [String: String]
    let message: [String: String]
    let downloadURL: URL
    let expiresAt: Date?

    func title(for locale: Locale) -> String {
        localizedValue(title, locale: locale) ?? hardware
    }

    func message(for locale: Locale) -> String {
        localizedValue(message, locale: locale) ?? hardware
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    private func localizedValue(_ values: [String: String], locale: Locale) -> String? {
        let preferred = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = locale.language.languageCode?.identifier ?? "en"
        return values[preferred]
            ?? values[language]
            ?? values["en"]
            ?? values.values.first
    }
}

private struct HardwareAnnouncementEnvelope: Decodable {
    let announcements: [HardwareAnnouncement]
}

enum HardwareAnnouncementSource {
    static let defaultURL = OfflineRuntimePolicy.disabledExternalURL

    static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        _ = bundle
        _ = environment
        return defaultURL
    }
}

final class HardwareAnnouncementStore: ObservableObject {
    @Published private(set) var announcements: [HardwareAnnouncement] = []
    @Published private(set) var isLoading = false

    private let logger: (String) -> Void
    private var requestGeneration = 0

    init(
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.logger = logger
    }

    func refresh() {
        requestGeneration &+= 1
        isLoading = false
        announcements = []
        logger("HARDWARE ANNOUNCEMENT request_skipped reason=offline_only")
    }
}

private extension JSONDecoder {
    static var hardwareAnnouncement: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
