import Foundation

/// Google Chromecast 语音遥控器在本地蓝牙层可观察的身份。
///
/// ATVV service UUID 由多个厂商共用，不能作为型号身份。此规则刻意要求名称、厂商和
/// DIS 型号都相符；任一项缺失或不符时，适配器不能将设备标为可用。
enum ChromecastRemoteIdentity {
    static let bluetoothName = "Chromecast Remote"
    static let manufacturer = "Google Inc."
    static let modelNumber = "A0"
    static let hidVendorID = 0x18D1
    static let hidProductID = 0x9450

    static func matchesAdvertisedName(_ name: String?) -> Bool {
        name?.trimmingCharacters(in: .whitespacesAndNewlines) == bluetoothName
    }

    static func matchesDeviceInformation(
        manufacturer: String?,
        modelNumber: String?
    ) -> Bool {
        manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.manufacturer &&
            modelNumber?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.modelNumber
    }

    static func matchesHID(vendorID: Int, productID: Int) -> Bool {
        vendorID == hidVendorID && productID == hidProductID
    }
}
