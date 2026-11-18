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

    @Test func publicAdapterDeclaresVoiceAndOrdinaryControlEdges() {
        #expect(ChromecastFeatureIntegration.publicDeclaredCapabilities == [
            .controlEdges,
            .voiceStream,
        ])
        #expect(ChromecastFeatureIntegration.supportsOrdinaryControlEdges)
        #expect(!ChromecastFeatureIntegration.requiresNativeInputPreparation)
    }

    @Test func decodesEveryConfirmedA0ControlUsage() {
        let expected: [UInt8: ChromecastRemoteControl] = [
            0x01: .power,
            0x03: .up,
            0x04: .down,
            0x05: .left,
            0x06: .right,
            0x07: .select,
            0x08: .mute,
            0x0A: .home,
            0x0B: .back,
            0x0C: .volumeUp,
            0x0D: .volumeDown,
            0x0E: .youtube,
            0x0F: .netflix,
            0x11: .input,
        ]
        #expect(expected.count == ChromecastRemoteControl.allCases.count)
        for (usage, control) in expected {
            #expect(ChromecastGATTControlDecoder.control(for: usage) == control)
        }
        #expect(ChromecastGATTControlDecoder.control(for: 0x02) == nil)
    }

    @Test func emitsPairedEdgesAndIgnoresDuplicateReports() throws {
        var decoder = ChromecastGATTControlDecoder()
        let pressed = decoder.ingest(Data([0x08, 0, 0, 0, 0, 0, 0, 0]))
        #expect(pressed.count == 1)
        #expect(try #require(pressed.first).control == .mute)
        #expect(try #require(pressed.first).phase == .began)
        #expect(decoder.ingest(Data([0x08, 0, 0, 0, 0, 0, 0, 0])).isEmpty)

        let released = decoder.ingest(Data(repeating: 0, count: 8))
        #expect(released.count == 1)
        #expect(try #require(released.first).control == .mute)
        #expect(try #require(released.first).phase == .ended)
        #expect(try #require(released.first).sequence > #require(pressed.first).sequence)
        #expect(decoder.ingest(Data(repeating: 0, count: 8)).isEmpty)
    }

    @Test func cancelsAnActiveControlOnReplacementMalformedInputAndDisconnect() throws {
        var decoder = ChromecastGATTControlDecoder()
        _ = decoder.ingest(Data([0x0B, 0, 0, 0, 0, 0, 0, 0]))
        let replacement = decoder.ingest(Data([0x0A, 0, 0, 0, 0, 0, 0, 0]))
        #expect(replacement.map(\.phase) == [.cancelled, .began])
        #expect(replacement.first?.control == .back)
        #expect(replacement.last?.control == .home)

        let malformed = decoder.ingest(Data([0x0A, 1, 0, 0, 0, 0, 0, 0]))
        #expect(malformed.count == 1)
        #expect(try #require(malformed.first).phase == .cancelled)
        #expect(try #require(malformed.first).cancellationReason == "malformed_report")

        _ = decoder.ingest(Data([0x0E, 0, 0, 0, 0, 0, 0, 0]))
        let cancellation = decoder.cancel(reason: "disconnect")
        let disconnected = try #require(cancellation)
        #expect(disconnected.control == .youtube)
        #expect(disconnected.phase == .cancelled)
        #expect(disconnected.cancellationReason == "disconnect")
        #expect(decoder.activeControl == nil)
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
