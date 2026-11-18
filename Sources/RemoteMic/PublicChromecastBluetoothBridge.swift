import CoreBluetooth
import Foundation

enum ChromecastATVVControl {
    static func supportsHoldStream(_ capabilities: ATVVCapabilities) -> Bool {
        capabilities.version >= 0x0100 && capabilities.selectedCodec == 0x02 &&
            capabilities.interaction == 0x03 && capabilities.sampleRate == 16_000 &&
            (capabilities.frameSize == 160 || capabilities.frameSize == 247)
    }

    static func streamCodec(_ data: Data) -> UInt8? {
        guard data.count >= 4, data[0] == 0x04 else { return nil }
        return data[2]
    }

    static func physicalHoldStreamID(_ data: Data, codec: UInt8) -> UInt8? {
        guard streamCodec(data) == codec, data[1] == 0x03,
              data[3] > 0, data[3] <= 0x80 else { return nil }
        return data[3]
    }

    static func syncState(_ data: Data) -> (predictor: Int, stepIndex: Int)? {
        guard data.count >= 7, data[0] == 0x0A else { return nil }
        let prediction = UInt16(data[4]) << 8 | UInt16(data[5])
        return (Int(Int16(bitPattern: prediction)), Int(data[6]))
    }
}

/// Decodes the confirmed A0 remote's HID-over-GATT input report.
///
/// The report characteristic sends eight-byte Array reports: byte zero is the
/// physical control usage and the remaining bytes are zero. A zero usage is the
/// release edge. Keeping this state machine outside CoreBluetooth makes paired
/// edge and cancellation behavior deterministic and directly testable.
struct ChromecastGATTControlDecoder {
    private(set) var activeControl: ChromecastRemoteControl?
    private(set) var sequence = 0

    mutating func ingest(_ data: Data) -> [ChromecastRemoteControlEvent] {
        guard data.count == 8, data.dropFirst().allSatisfy({ $0 == 0 }) else {
            return cancel(reason: "malformed_report").map { [$0] } ?? []
        }
        guard let usage = data.first else { return [] }
        guard usage != 0 else {
            guard let activeControl else { return [] }
            self.activeControl = nil
            return [event(control: activeControl, phase: .ended)]
        }
        guard let control = Self.control(for: usage) else {
            return cancel(reason: "unsupported_usage").map { [$0] } ?? []
        }
        guard control != activeControl else { return [] }

        var events: [ChromecastRemoteControlEvent] = []
        if let activeControl {
            events.append(event(
                control: activeControl,
                phase: .cancelled,
                cancellationReason: "replaced_by_new_press"
            ))
        }
        self.activeControl = control
        events.append(event(control: control, phase: .began))
        return events
    }

    mutating func cancel(reason: String) -> ChromecastRemoteControlEvent? {
        guard let activeControl else { return nil }
        self.activeControl = nil
        return event(
            control: activeControl,
            phase: .cancelled,
            cancellationReason: reason
        )
    }

    static func control(for usage: UInt8) -> ChromecastRemoteControl? {
        switch usage {
        case 0x01: return .power
        case 0x03: return .up
        case 0x04: return .down
        case 0x05: return .left
        case 0x06: return .right
        case 0x07: return .select
        case 0x08: return .mute
        case 0x0A: return .home
        case 0x0B: return .back
        case 0x0C: return .volumeUp
        case 0x0D: return .volumeDown
        case 0x0E: return .youtube
        case 0x0F: return .netflix
        case 0x11: return .input
        default: return nil
        }
    }

    private mutating func event(
        control: ChromecastRemoteControl,
        phase: ChromecastRemoteControlPhase,
        cancellationReason: String? = nil
    ) -> ChromecastRemoteControlEvent {
        sequence &+= 1
        return ChromecastRemoteControlEvent(
            control: control,
            phase: phase,
            sequence: sequence,
            cancellationReason: cancellationReason
        )
    }
}

/// Public, local-only ATVV receiver for the confirmed Google Chromecast remote.
/// It is intentionally narrow: shared ATVV UUIDs, renamed devices, unverified
/// DIS values and unsupported codecs never become a usable connection.
final class PublicChromecastBluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatusChange: ((ChromecastLinkStatus) -> Void)?
    var onDeclaredCapabilitiesChange: ((ChromecastDeclaredCapabilities) -> Void)?
    var onVoiceStart: (() -> Void)?
    var onVoiceStop: ((ChromecastVoiceEndReason) -> Void)?
    var onControlEvent: ((ChromecastRemoteControlEvent) -> Void)?
    var onHIDPresenceChange: ((Bool) -> Void)?
    var onSamples: (([Int16], Int) -> Void)?
    var onLog: ((String) -> Void)?

    private let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    private let deviceInformationUUID = CBUUID(string: "180A")
    private let manufacturerUUID = CBUUID(string: "2A29")
    private let modelUUID = CBUUID(string: "2A24")
    private let hidServiceUUID = CBUUID(string: "1812")
    private let hidReportUUID = CBUUID(string: "2A4D")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var capabilities: ATVVCapabilities?
    private var manufacturer: String?
    private var model: String?
    private var subscribed = Set<CBUUID>()
    private var subscribedHIDReports = Set<ObjectIdentifier>()
    /// A HID service can expose more than one Report characteristic. Keep one
    /// decoder per notification channel so an unrelated channel's zero report
    /// cannot release a button that was pressed on the actual control channel.
    private var controlDecoders: [ObjectIdentifier: ChromecastGATTControlDecoder] = [:]
    private(set) var isHIDRemotePresent = false
    private var controlMappingEnabled = false
    private var decoder = IMAADPCMDecoder()
    private var frames = FrameAccumulator()
    private var pendingSync: (predictor: Int, stepIndex: Int)?
    private var syncFramesToSkip = 0
    private var streaming = false
    private var generation: Int = 0
    private var shouldRun = false
    private var capabilityRequestSent = false
    private var blockedByFailure = false

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        blockedByFailure = false
        generation &+= 1
        onStatusChange?(.searching)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        // Some CoreBluetooth implementations report the initial state during
        // construction, before `central` has been assigned. Recheck once on
        // the next main-queue turn so that first launch cannot stay searching.
        DispatchQueue.main.async { [weak self] in
            guard let self, let central = self.central, self.shouldRun else { return }
            self.onLog?("CHROMECAST BLE phase=central_init result=observed state=\(central.state.rawValue)")
            if central.state != .unknown { self.centralManagerDidUpdateState(central) }
        }
    }

    func stop() {
        shouldRun = false
        blockedByFailure = false
        central?.stopScan()
        if let peripheral, peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
        resetSession(reason: .hostStop)
        resetControls(reason: "host_stop")
        peripheral = nil
        transmit = nil
        central?.delegate = nil
        central = nil
        onDeclaredCapabilitiesChange?([])
        onStatusChange?(.disabled)
    }

    func reconnect() {
        guard shouldRun else { return }
        blockedByFailure = false
        central?.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        } else if let central, central.state == .poweredOn {
            discover(using: central)
        }
    }

    func notifyHostVoiceSessionEnded() {
        resetSession(reason: .hostStop)
    }

    func setControlMappingEnabled(_ enabled: Bool) {
        guard controlMappingEnabled != enabled else { return }
        controlMappingEnabled = enabled
        onLog?("CHROMECAST GATT mapping=\(enabled ? "enabled" : "disabled") result=applied")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, shouldRun, !blockedByFailure else { return }
        guard central.state == .poweredOn else {
            resetSession(reason: .cancelled("central_unavailable"))
            resetControls(reason: "central_unavailable")
            onDeclaredCapabilitiesChange?([])
            onStatusChange?(.unauthorized)
            onLog?("CHROMECAST BLE phase=unavailable result=failed reason=central_not_powered")
            return
        }
        discover(using: central)
    }

    private func discover(using central: CBCentralManager) {
        guard shouldRun, !blockedByFailure else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let candidate = connected.first(where: { ChromecastRemoteIdentity.matchesAdvertisedName($0.name) }) {
            connect(candidate, using: central, source: "connected")
            return
        }
        onStatusChange?(.searching)
        if !central.isScanning {
            central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            onLog?("CHROMECAST BLE phase=scanning result=started")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, shouldRun, !blockedByFailure, self.peripheral == nil else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard ChromecastRemoteIdentity.matchesAdvertisedName(advertised ?? peripheral.name) else { return }
        connect(peripheral, using: central, source: "scan")
    }

    private func connect(_ candidate: CBPeripheral, using central: CBCentralManager, source: String) {
        guard peripheral == nil else { return }
        peripheral = candidate
        central.stopScan()
        onStatusChange?(.connecting)
        onLog?("CHROMECAST BLE phase=connecting result=requested source=\(source)")
        central.connect(candidate)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, shouldRun, !blockedByFailure else { return }
        capabilityRequestSent = false
        capabilities = nil
        manufacturer = nil
        model = nil
        subscribed.removeAll()
        resetControls(reason: "reconnecting")
        peripheral.delegate = self
        onStatusChange?(.searching)
        peripheral.discoverServices([serviceUUID, deviceInformationUUID, hidServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        self.peripheral = nil
        resetSession(reason: .cancelled("connect_failed"))
        resetControls(reason: "connect_failed")
        onDeclaredCapabilitiesChange?([])
        onStatusChange?(.disconnected)
        onLog?("CHROMECAST BLE phase=connecting result=failed reason=connect_failed retry_delay_ms=2000")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak central] in
            guard let self, let central, self.central === central,
                  self.shouldRun, !self.blockedByFailure, self.peripheral == nil,
                  central.state == .poweredOn else { return }
            self.discover(using: central)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        resetSession(reason: .cancelled("disconnect"))
        resetControls(reason: "disconnect")
        self.peripheral = nil
        transmit = nil
        onDeclaredCapabilitiesChange?([])
        if !blockedByFailure { onStatusChange?(.disconnected) }
        if shouldRun, !blockedByFailure, central.state == .poweredOn { discover(using: central) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, shouldRun, !blockedByFailure else { return }
        guard error == nil else { fail("service_discovery"); return }
        guard let voice = peripheral.services?.first(where: { $0.uuid == serviceUUID }),
              let information = peripheral.services?.first(where: { $0.uuid == deviceInformationUUID }) else {
            fail("required_service_missing")
            return
        }
        peripheral.discoverCharacteristics([transmitUUID, audioUUID, controlUUID], for: voice)
        peripheral.discoverCharacteristics([manufacturerUUID, modelUUID], for: information)
        if let hid = peripheral.services?.first(where: { $0.uuid == hidServiceUUID }) {
            peripheral.discoverCharacteristics([hidReportUUID], for: hid)
        } else {
            onLog?("CHROMECAST GATT phase=service_discovery result=unavailable reason=hid_service_missing")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, shouldRun, !blockedByFailure else { return }
        if service.uuid == hidServiceUUID {
            guard error == nil else {
                onLog?("CHROMECAST GATT phase=characteristic_discovery result=unavailable reason=discovery_failed")
                return
            }
            let reports = (service.characteristics ?? []).filter {
                $0.uuid == hidReportUUID && ($0.properties.contains(.notify) || $0.properties.contains(.indicate))
            }
            guard !reports.isEmpty else {
                onLog?("CHROMECAST GATT phase=characteristic_discovery result=unavailable reason=input_report_missing")
                return
            }
            reports.forEach { peripheral.setNotifyValue(true, for: $0) }
            return
        }
        guard error == nil else { fail("characteristic_discovery"); return }
        if service.uuid == deviceInformationUUID {
            let found = Set((service.characteristics ?? []).map(\.uuid))
            guard found.contains(manufacturerUUID), found.contains(modelUUID) else {
                fail("device_information_incomplete")
                return
            }
            for characteristic in service.characteristics ?? [] where characteristic.uuid == manufacturerUUID || characteristic.uuid == modelUUID {
                peripheral.readValue(for: characteristic)
            }
            return
        }
        guard service.uuid == serviceUUID else { return }
        var found = Set<CBUUID>()
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == transmitUUID { transmit = characteristic; found.insert(transmitUUID) }
            if characteristic.uuid == audioUUID || characteristic.uuid == controlUUID {
                found.insert(characteristic.uuid)
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        guard found.contains(transmitUUID), found.contains(audioUUID), found.contains(controlUUID) else {
            fail("atvv_channel_incomplete")
            return
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, shouldRun, !blockedByFailure else { return }
        if characteristic.uuid == hidReportUUID {
            let identifier = ObjectIdentifier(characteristic)
            if error == nil, characteristic.isNotifying {
                subscribedHIDReports.insert(identifier)
                controlDecoders[identifier] = controlDecoders[identifier]
                    ?? ChromecastGATTControlDecoder()
                updateControlAvailability()
            } else {
                subscribedHIDReports.remove(identifier)
                if var decoder = controlDecoders.removeValue(forKey: identifier),
                   let cancelled = decoder.cancel(reason: "notification_stopped") {
                    onControlEvent?(cancelled)
                }
                updateControlAvailability()
                onLog?("CHROMECAST GATT phase=subscription result=unavailable reason=notification_failed")
            }
            return
        }
        guard error == nil, characteristic.isNotifying else { fail("notification_subscription"); return }
        guard characteristic.uuid == audioUUID || characteristic.uuid == controlUUID else { return }
        subscribed.insert(characteristic.uuid)
        requestCapabilitiesIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, shouldRun, !blockedByFailure else { return }
        if error != nil, characteristic.uuid == manufacturerUUID || characteristic.uuid == modelUUID {
            fail("device_information_read")
            return
        }
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == manufacturerUUID { manufacturer = String(data: value, encoding: .utf8); requestCapabilitiesIfReady(); return }
        if characteristic.uuid == modelUUID { model = String(data: value, encoding: .utf8); requestCapabilitiesIfReady(); return }
        if characteristic.uuid == hidReportUUID {
            handleHIDReport(value, from: characteristic)
            return
        }
        if characteristic.uuid == controlUUID { handleControl(value); return }
        if characteristic.uuid == audioUUID { handleAudio(value) }
    }

    private func requestCapabilitiesIfReady() {
        guard !capabilityRequestSent, !blockedByFailure,
              subscribed == Set([audioUUID, controlUUID]), manufacturer != nil, model != nil else { return }
        guard ChromecastRemoteIdentity.matchesDeviceInformation(manufacturer: manufacturer, modelNumber: model) else {
            fail("identity_mismatch")
            return
        }
        guard let transmit else { fail("transmit_missing"); return }
        guard transmit.properties.contains(.writeWithoutResponse) else {
            fail("transmit_write_unsupported")
            return
        }
        capabilityRequestSent = true
        peripheral?.writeValue(ATVVProtocol.getCapabilitiesV10, for: transmit, type: .withoutResponse)
        onLog?("CHROMECAST ATVV phase=capabilities result=requested")
    }

    private func handleControl(_ data: Data) {
        guard let opcode = data.first else { return }
        switch opcode {
        case 0x0B:
            guard capabilityRequestSent else { return }
            guard let parsed = ATVVCapabilities.parse(data) else {
                onLog?("CHROMECAST ATVV phase=capabilities result=failed reason=malformed byte_count=\(data.count)")
                fail("capabilities_malformed")
                return
            }
            onLog?("CHROMECAST ATVV phase=capabilities result=observed version=\(parsed.version) codecs=\(parsed.codecs) interaction=\(parsed.interaction) frame_bytes=\(parsed.frameSize) sample_rate_hz=\(Int(parsed.sampleRate))")
            guard ChromecastATVVControl.supportsHoldStream(parsed) else {
                fail("unsupported_audio_format")
                return
            }
            capabilities = parsed
            publishDeclaredCapabilities()
            updateControlAvailability()
            onStatusChange?(.connected(displayName: ChromecastRemoteIdentity.bluetoothName))
            onLog?("CHROMECAST ATVV phase=ready result=passed sample_rate_hz=16000 frame_bytes=\(parsed.frameSize)")
        case 0x04:
            guard let capabilities, capabilities.sampleRate == 16_000 else { return }
            guard let codec = ChromecastATVVControl.streamCodec(data) else {
                fail("stream_start_incomplete")
                return
            }
            guard data[1] == 0x03 else {
                onLog?("CHROMECAST VOICE phase=ignored result=non_physical_start")
                return
            }
            guard codec == capabilities.selectedCodec else { fail("stream_codec"); return }
            guard ChromecastATVVControl.physicalHoldStreamID(data, codec: codec) != nil else {
                onLog?("CHROMECAST VOICE phase=ignored result=invalid_stream_id")
                return
            }
            guard !streaming else { return }
            streaming = true
            generation &+= 1
            frames.reset()
            pendingSync = nil
            syncFramesToSkip = 0
            decoder.reset()
            onVoiceStart?()
            onLog?("CHROMECAST VOICE phase=started result=received generation=\(generation)")
        case 0x00:
            guard streaming else { return }
            if !frames.pending.isEmpty {
                if syncFramesToSkip == 0, let pendingSync {
                    decoder.reset(predictor: pendingSync.predictor, stepIndex: pendingSync.stepIndex)
                }
                onSamples?(PCMPostprocessor.process(decoder.decode(frames.pending), gainDB: 0), generation)
                onLog?("CHROMECAST VOICE phase=tail result=decoded generation=\(generation) bytes=\(frames.pending.count)")
            }
            streaming = false
            frames.reset()
            pendingSync = nil
            syncFramesToSkip = 0
            onVoiceStop?(.holdRelease)
            onLog?("CHROMECAST VOICE phase=stopping result=received generation=\(generation)")
        case 0x08:
            // The confirmed HTT remote starts its own stream. Sending MIC_OPEN
            // after its physical press split the stream in prior device tests.
            onLog?("CHROMECAST ATVV phase=mic_open result=skipped reason=remote_initiated_stream")
        case 0x0A:
            guard let sync = ChromecastATVVControl.syncState(data) else { return }
            pendingSync = sync
            syncFramesToSkip = frames.pending.isEmpty ? 0 : 1
        default: break
        }
    }

    private func handleAudio(_ data: Data) {
        guard streaming, let capabilities else { return }
        for frame in frames.append(data, frameSize: capabilities.frameSize) {
            if syncFramesToSkip > 0 {
                syncFramesToSkip -= 1
            } else if let pendingSync {
                decoder.reset(predictor: pendingSync.predictor, stepIndex: pendingSync.stepIndex)
                self.pendingSync = nil
            }
            onSamples?(PCMPostprocessor.process(decoder.decode(frame), gainDB: 0), generation)
        }
    }

    private func handleHIDReport(_ data: Data, from characteristic: CBCharacteristic) {
        guard capabilities != nil else { return }
        let identifier = ObjectIdentifier(characteristic)
        guard subscribedHIDReports.contains(identifier) else { return }
        var decoder = controlDecoders[identifier] ?? ChromecastGATTControlDecoder()
        let events = decoder.ingest(data)
        controlDecoders[identifier] = decoder
        for event in events {
            onControlEvent?(event)
        }
    }

    private func updateControlAvailability() {
        let available = capabilities != nil && !subscribedHIDReports.isEmpty
        guard available != isHIDRemotePresent else { return }
        isHIDRemotePresent = available
        onHIDPresenceChange?(available)
        publishDeclaredCapabilities()
        onLog?(
            "CHROMECAST GATT phase=controls result=\(available ? "ready" : "unavailable") " +
                "report_channels=\(subscribedHIDReports.count)"
        )
    }

    private func publishDeclaredCapabilities() {
        guard capabilities != nil else {
            onDeclaredCapabilitiesChange?([])
            return
        }
        var declared: ChromecastDeclaredCapabilities = [.voiceStream]
        if isHIDRemotePresent { declared.insert(.controlEdges) }
        onDeclaredCapabilitiesChange?(declared)
    }

    private func resetControls(reason: String) {
        for identifier in controlDecoders.keys {
            guard var decoder = controlDecoders[identifier],
                  let cancelled = decoder.cancel(reason: reason)
            else { continue }
            onControlEvent?(cancelled)
        }
        controlDecoders.removeAll()
        subscribedHIDReports.removeAll()
        guard isHIDRemotePresent else { return }
        isHIDRemotePresent = false
        onHIDPresenceChange?(false)
    }

    private func resetSession(reason: ChromecastVoiceEndReason) {
        guard streaming else { return }
        streaming = false
        frames.reset()
        pendingSync = nil
        syncFramesToSkip = 0
        onVoiceStop?(reason)
    }

    private func fail(_ reason: String) {
        guard !blockedByFailure else { return }
        blockedByFailure = true
        resetSession(reason: .cancelled(reason))
        resetControls(reason: reason)
        onDeclaredCapabilitiesChange?([])
        onStatusChange?(.unsupported(reason: reason))
        onLog?("CHROMECAST BLE phase=failed result=failed reason=\(reason)")
        if let peripheral {
            if peripheral.state == .disconnected {
                self.peripheral = nil
            } else {
                central?.cancelPeripheralConnection(peripheral)
            }
        }
    }
}
