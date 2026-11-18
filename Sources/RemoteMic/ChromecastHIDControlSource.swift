import Foundation
import IOKit.hid

private func chromecastHIDDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<ChromecastHIDControlSource>
        .fromOpaque(context)
        .takeUnretainedValue()
        .deviceDidMatch(result: result, device: device)
}

private func chromecastHIDDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<ChromecastHIDControlSource>
        .fromOpaque(context)
        .takeUnretainedValue()
        .deviceDidRemove(device: device)
}

private func chromecastHIDInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex,
    timeStamp: UInt64
) {
    guard let context else { return }
    let source = Unmanaged<ChromecastHIDControlSource>
        .fromOpaque(context)
        .takeUnretainedValue()
    guard result == kIOReturnSuccess else {
        source.reportWasRejected(result: result)
        return
    }
    guard reportLength > 0 else { return }
    source.receiveReport(
        reportID: reportID,
        data: Data(bytes: report, count: reportLength)
    )
}

/// Normalizes the genuine Chromecast Voice Remote's macOS IOHID report.
///
/// The BT-AACP virtual device reports `reportID=1` and bytes `01 XX 00` on
/// current macOS releases. Some IOHID callback variants strip the report-ID
/// byte and deliver `XX 00`; both forms describe the same Array usage. A zero
/// usage is the release edge.
struct ChromecastHIDReportDecoder {
    private(set) var controlDecoder = ChromecastControlEdgeDecoder()

    mutating func ingest(reportID: UInt32, data: Data) -> [ChromecastRemoteControlEvent] {
        guard let usage = Self.usage(reportID: reportID, data: data) else {
            return controlDecoder.cancel(reason: "malformed_hid_report").map { [$0] } ?? []
        }
        return controlDecoder.ingest(usage: usage)
    }

    mutating func cancel(reason: String) -> ChromecastRemoteControlEvent? {
        controlDecoder.cancel(reason: reason)
    }

    static func usage(reportID: UInt32, data: Data) -> UInt8? {
        guard reportID == 1 else { return nil }
        let bytes = Array(data)
        if bytes.count == 3, bytes[0] == UInt8(reportID), bytes[2] == 0 {
            return bytes[1]
        }
        if bytes.count == 2, bytes[1] == 0 {
            return bytes[0]
        }
        return nil
    }
}

/// Chooses one ordinary-button transport when both IOHID and GATT happen to
/// be available. IOHID is preferred because the paired-device CoreBluetooth
/// view can hide service 1812, and accepting both paths would double-dispatch.
enum ChromecastControlTransport {
    case ioHID
    case gatt
}

enum ChromecastControlTransportPolicy {
    static func accepts(
        _ transport: ChromecastControlTransport,
        ioHIDAvailable: Bool
    ) -> Bool {
        switch transport {
        case .ioHID: return true
        case .gatt: return !ioHIDAvailable
        }
    }
}

enum ChromecastPublicControlCapabilityPolicy {
    static func declared(
        voiceReady: Bool,
        ioHIDAvailable: Bool,
        gattAvailable: Bool,
        batteryAvailable: Bool = false
    ) -> ChromecastDeclaredCapabilities {
        guard voiceReady else { return [] }
        var declared: ChromecastDeclaredCapabilities = [.voiceStream]
        if ioHIDAvailable || gattAvailable { declared.insert(.controlEdges) }
        if batteryAvailable { declared.insert(.battery) }
        return declared
    }
}

/// Decodes the standard Bluetooth Battery Level characteristic (`2A19`).
///
/// The characteristic is one unsigned percentage byte. Values above 100 are
/// invalid and must never be presented as a user-facing battery percentage.
enum ChromecastBatteryLevelDecoder {
    static func decode(_ data: Data) -> Int? {
        guard data.count == 1, let value = data.first, value <= 100 else { return nil }
        return Int(value)
    }
}

/// Reads ordinary buttons from the genuine remote's macOS BT-AACP virtual HID
/// device. Voice remains on the public CoreBluetooth ATVV bridge.
///
/// Matching is deliberately exact: no device name, serial, address or broad
/// consumer-control match is used. Reports run on the same dedicated run-loop
/// pattern as Xiaomi HID so native Mute can be prearmed before the main queue.
final class ChromecastHIDControlSource {
    static let vendorID = 0x18D1
    static let productID = 0x9450

    var onPresenceChange: ((Bool) -> Void)?
    var onControlEvent: ((ChromecastRemoteControlEvent) -> Void)?
    var onControlPrearm: ((ChromecastRemoteControl) -> Void)?
    var onLog: ((String) -> Void)?

    private final class Registration {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let length: CFIndex
        let seized: Bool

        init(
            device: IOHIDDevice,
            buffer: UnsafeMutablePointer<UInt8>,
            length: CFIndex,
            seized: Bool
        ) {
            self.device = device
            self.buffer = buffer
            self.length = length
            self.seized = seized
        }
    }

    private let lock = NSLock()
    private let reportRunLoop = HIDReportRunLoop()
    private var manager: IOHIDManager?
    private var scheduledRunLoop: CFRunLoop?
    private var registrations: [UInt: Registration] = [:]
    private var retiredBuffers: [(UnsafeMutablePointer<UInt8>, CFIndex)] = []
    private var decoder = ChromecastHIDReportDecoder()
    private var running = false
    private var mappingEnabled = false
    private(set) var isPresent = false

    static func matches(vendorID: Int, productID: Int) -> Bool {
        vendorID == Self.vendorID && productID == Self.productID
    }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            chromecastHIDDeviceMatched,
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            chromecastHIDDeviceRemoved,
            context
        )

        let dedicated = reportRunLoop.start()
        let runLoop = dedicated ?? RunLoop.main.getCFRunLoop()
        scheduledRunLoop = runLoop
        IOHIDManagerScheduleWithRunLoop(
            manager,
            runLoop,
            CFRunLoopMode.commonModes.rawValue
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                runLoop,
                CFRunLoopMode.commonModes.rawValue
            )
            scheduledRunLoop = nil
            lock.lock()
            running = false
            lock.unlock()
            _ = reportRunLoop.stop()
            log(
                "CHROMECAST IOHID phase=manager_open result=failed " +
                    AppLogger.errorFields(domain: "io_return", code: Int(result))
            )
            return
        }
        self.manager = manager
        log(
            dedicated == nil
                ? "CHROMECAST IOHID phase=runloop result=fallback mode=main"
                : "CHROMECAST IOHID phase=runloop result=ready mode=dedicated"
        )
    }

    func stop() {
        lock.lock()
        running = false
        let currentRegistrations = Array(registrations.values)
        registrations.removeAll()
        lock.unlock()

        for registration in currentRegistrations {
            unregister(registration)
        }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                scheduledRunLoop ?? RunLoop.main.getCFRunLoop(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        scheduledRunLoop = nil
        if reportRunLoop.stop() { releaseRetiredBuffers() }
        if let cancelled = decoder.cancel(reason: "host_stop") {
            onControlEvent?(cancelled)
        }
        setPresence(false)
    }

    func setMappingEnabled(_ enabled: Bool) {
        lock.lock()
        mappingEnabled = enabled
        lock.unlock()
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else {
            log("CHROMECAST IOHID phase=device_match result=failed")
            return
        }
        let vendor = Self.integerProperty(device, key: kIOHIDVendorIDKey)
        let product = Self.integerProperty(device, key: kIOHIDProductIDKey)
        guard Self.matches(vendorID: vendor, productID: product) else { return }

        let pointer = Self.pointer(device)
        lock.lock()
        let shouldRegister = running && registrations[pointer] == nil
        lock.unlock()
        guard shouldRegister else { return }

        let seizeResult = IOHIDDeviceOpen(
            device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
        let seized = seizeResult == kIOReturnSuccess
        let openResult = seized
            ? seizeResult
            : IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            log(
                "CHROMECAST IOHID phase=device_open result=failed " +
                    AppLogger.errorFields(
                        domain: "io_return",
                        code: Int(seizeResult),
                        fieldPrefix: "seize_error"
                    ) + " " +
                    AppLogger.errorFields(
                        domain: "io_return",
                        code: Int(openResult),
                        fieldPrefix: "monitor_error"
                    )
            )
            return
        }

        let maximumLength = Self.integerProperty(
            device,
            key: kIOHIDMaxInputReportSizeKey
        )
        let length = CFIndex(max(64, maximumLength))
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(length))
        buffer.initialize(repeating: 0, count: Int(length))
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device,
            buffer,
            length,
            chromecastHIDInputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            scheduledRunLoop ?? RunLoop.main.getCFRunLoop(),
            CFRunLoopMode.commonModes.rawValue
        )
        let registration = Registration(
            device: device,
            buffer: buffer,
            length: length,
            seized: seized
        )
        lock.lock()
        if running, registrations[pointer] == nil {
            registrations[pointer] = registration
            lock.unlock()
            log(
                "CHROMECAST IOHID phase=device_open result=ready " +
                    "mode=\(seized ? "seized" : "monitored")"
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillPresent = self.running && !self.registrations.isEmpty
                self.lock.unlock()
                if stillPresent { self.setPresence(true) }
            }
        } else {
            lock.unlock()
            unregister(registration)
        }
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        let pointer = Self.pointer(device)
        lock.lock()
        let registration = registrations.removeValue(forKey: pointer)
        let hasRemainingDevice = !registrations.isEmpty
        lock.unlock()
        guard let registration else { return }
        unregister(registration)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let cancelled = self.decoder.cancel(reason: "device_removed") {
                self.onControlEvent?(cancelled)
            }
            self.setPresence(hasRemainingDevice)
        }
    }

    fileprivate func receiveReport(reportID: UInt32, data: Data) {
        // The virtual device also exposes Report IDs 4 and 8. They are not
        // ordinary controls and must not cancel a button currently held on ID 1.
        guard reportID == 1 else { return }
        guard let usage = ChromecastHIDReportDecoder.usage(
            reportID: reportID,
            data: data
        ) else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let cancelled = self.decoder.cancel(reason: "malformed_hid_report") {
                    self.onControlEvent?(cancelled)
                }
                self.log("CHROMECAST IOHID phase=report result=ignored reason=malformed")
            }
            return
        }

        lock.lock()
        let shouldPrearm = running && mappingEnabled
        lock.unlock()
        if shouldPrearm, usage != 0,
           let control = ChromecastControlEdgeDecoder.control(for: usage),
           !ChromecastRemoteControl.isSystemManaged(
               control,
               allowSystemReservedKeys: false
           ) {
            onControlPrearm?(control)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isRunning = self.running
            self.lock.unlock()
            guard isRunning else { return }
            let events = self.decoder.ingest(reportID: reportID, data: data)
            for event in events { self.onControlEvent?(event) }
        }
    }

    fileprivate func reportWasRejected(result: IOReturn) {
        log(
            "CHROMECAST IOHID phase=report result=failed " +
                AppLogger.errorFields(domain: "io_return", code: Int(result))
        )
    }

    private func unregister(_ registration: Registration) {
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            registration.device,
            registration.buffer,
            registration.length,
            nil,
            nil
        )
        if let scheduledRunLoop {
            IOHIDDeviceUnscheduleFromRunLoop(
                registration.device,
                scheduledRunLoop,
                CFRunLoopMode.commonModes.rawValue
            )
        }
        IOHIDDeviceClose(registration.device, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        retiredBuffers.append((registration.buffer, registration.length))
        lock.unlock()
    }

    private func releaseRetiredBuffers() {
        lock.lock()
        let buffers = retiredBuffers
        retiredBuffers.removeAll()
        lock.unlock()
        for (buffer, length) in buffers {
            buffer.deinitialize(count: Int(length))
            buffer.deallocate()
        }
    }

    private func setPresence(_ present: Bool) {
        guard isPresent != present else { return }
        isPresent = present
        onPresenceChange?(present)
        log(
            "CHROMECAST IOHID phase=controls result=\(present ? "ready" : "unavailable")"
        )
    }

    private func log(_ message: String) {
        if Thread.isMainThread {
            onLog?(message)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
        }
    }

    private static func integerProperty(_ device: IOHIDDevice, key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
    }

    private static func pointer(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    deinit {
        _ = reportRunLoop.stop(waitTimeout: 0.5)
        releaseRetiredBuffers()
    }
}
