import Foundation
import Testing
@testable import RemoteMic

@Suite("Chromecast remote identity")
struct ChromecastRemoteIdentityTests {
    @Test func validatesTheChromecastATVVControlShape() {
        #expect(ChromecastATVVControl.streamCodec(Data([0x04, 0x00, 0x02, 0x07])) == 0x02)
        #expect(ChromecastATVVControl.streamCodec(Data([0x04, 0x00, 0x02])) == nil)
        #expect(ChromecastATVVControl.streamCodec(Data([0x00, 0x00, 0x02, 0x07])) == nil)
        #expect(ChromecastATVVControl.syncState(Data([0x0A, 0, 0, 0, 0xFF, 0xFE, 88]))?.predictor == -2)
        #expect(ChromecastATVVControl.syncState(Data([0x0A, 0, 0])) == nil)
    }

    @Test func ignoresNonPhysicalOrGhostAudioStarts() {
        #expect(ChromecastATVVControl.physicalHoldStreamID(Data([0x04, 0x03, 0x02, 0x0E]), codec: 0x02) == 0x0E)
        #expect(ChromecastATVVControl.physicalHoldStreamID(Data([0x04, 0x00, 0x02, 0x00]), codec: 0x02) == nil)
        #expect(ChromecastATVVControl.physicalHoldStreamID(Data([0x04, 0x03, 0x02, 0x00]), codec: 0x02) == nil)
        #expect(ChromecastATVVControl.physicalHoldStreamID(Data([0x04, 0x03, 0x01, 0x0F]), codec: 0x02) == nil)
    }

    @Test func publicAdapterDeclaresOnlyItsImplementedCapability() {
        #expect(ChromecastFeatureIntegration.publicDeclaredCapabilities == [.voiceStream])
        #expect(!ChromecastFeatureIntegration.publicDeclaredCapabilities.contains(.controlEdges))
    }

    @Test func parsesThePreviouslyObservedChromecastCapabilityShape() {
        let capabilities = ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0xF7, 0x01, 0x00]))
        #expect(capabilities?.version == 0x0100)
        #expect(capabilities?.selectedCodec == 0x02)
        #expect(capabilities?.interaction == 0x03)
        #expect(capabilities?.frameSize == 247)
        #expect(capabilities?.sampleRate == 16_000)
    }

    @Test func acceptsTheCurrentAndPreviouslyObservedFrameSizes() {
        let current = ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0xA0]))!
        let previous = ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0xF7]))!
        let other = ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78]))!
        #expect(ChromecastATVVControl.supportsHoldStream(current))
        #expect(ChromecastATVVControl.supportsHoldStream(previous))
        #expect(!ChromecastATVVControl.supportsHoldStream(other))
    }

    @Test func acceptsOnlyTheConfirmedBluetoothName() {
        #expect(ChromecastRemoteIdentity.matchesAdvertisedName("Chromecast Remote"))
        #expect(!ChromecastRemoteIdentity.matchesAdvertisedName("chromecast remote"))
        #expect(!ChromecastRemoteIdentity.matchesAdvertisedName("MI RC"))
        #expect(!ChromecastRemoteIdentity.matchesAdvertisedName(nil))
    }

    @Test func requiresBothDISIdentityFields() {
        #expect(ChromecastRemoteIdentity.matchesDeviceInformation(
            manufacturer: "Google Inc.", modelNumber: "A0"
        ))
        #expect(!ChromecastRemoteIdentity.matchesDeviceInformation(
            manufacturer: "Google Inc.", modelNumber: "RC003"
        ))
        #expect(!ChromecastRemoteIdentity.matchesDeviceInformation(
            manufacturer: "Xiaomi", modelNumber: "A0"
        ))
    }

    @Test func acceptsOnlyTheConfirmedHIDDevice() {
        #expect(ChromecastRemoteIdentity.matchesHID(vendorID: 0x18D1, productID: 0x9450))
        #expect(!ChromecastRemoteIdentity.matchesHID(vendorID: 0x18D1, productID: 0x9451))
    }
}
