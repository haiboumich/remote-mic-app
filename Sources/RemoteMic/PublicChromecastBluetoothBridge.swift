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

/// Public, local-only ATVV receiver for the confirmed Google Chromecast remote.
/// It is intentionally narrow: shared ATVV UUIDs, renamed devices, unverified
/// DIS values and unsupported codecs never become a usable connection.
final class PublicChromecastBluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatusChange: ((ChromecastLinkStatus) -> Void)?
    var onDeclaredCapabilitiesChange: ((ChromecastDeclaredCapabilities) -> Void)?
    var onVoiceStart: (() -> Void)?
    var onVoiceStop: ((ChromecastVoiceEndReason) -> Void)?
    var onSamples: (([Int16], Int) -> Void)?
    var onLog: ((String) -> Void)?

    private let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    private let deviceInformationUUID = CBUUID(string: "180A")
    private let manufacturerUUID = CBUUID(string: "2A29")
    private let modelUUID = CBUUID(string: "2A24")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var capabilities: ATVVCapabilities?
    private var manufacturer: String?
    private var model: String?
    private var subscribed = Set<CBUUID>()
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

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, shouldRun, !blockedByFailure else { return }
        guard central.state == .poweredOn else {
            resetSession(reason: .cancelled("central_unavailable"))
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
        peripheral.delegate = self
        onStatusChange?(.searching)
        peripheral.discoverServices([serviceUUID, deviceInformationUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        self.peripheral = nil
        resetSession(reason: .cancelled("connect_failed"))
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
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, shouldRun, !blockedByFailure else { return }
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
            // This public adapter has no ordinary HID button edges yet.
            onDeclaredCapabilitiesChange?(ChromecastFeatureIntegration.publicDeclaredCapabilities)
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
