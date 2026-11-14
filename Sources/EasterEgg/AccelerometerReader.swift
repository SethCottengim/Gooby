import Foundation
import IOKit
import IOKit.hid

/// One accelerometer reading in g (1 g = gravity). Laptop flat on a desk ≈ (0, 0, -1).
struct AccelSample: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

/// Decodes the Apple-silicon MacBook motion sensor's 22-byte HID reports:
/// little-endian Int32 x / y / z at byte offsets 6 / 10 / 14, in units of 1/65536 g.
/// Measured on a Mac16,7 (M4 Pro) running macOS 26.7.1 (2026-11-11).
enum AccelReportDecoder {
    static let reportLength = 22
    static let offsets = (x: 6, y: 10, z: 14)
    static let countsPerG = 65536.0

    static func decode(_ bytes: [UInt8]) -> AccelSample? {
        guard bytes.count >= reportLength else { return nil }
        func int32(_ o: Int) -> Double {
            let v = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
            return Double(Int32(bitPattern: v)) / countsPerG
        }
        return AccelSample(x: int32(offsets.x), y: int32(offsets.y), z: int32(offsets.z))
    }
}

/// Streams the built-in accelerometer at 100 Hz during a storm. Uses IOKit HID
/// (vendor page 0xFF00, usage 3) on the AppleSPU sensor hub; needs no admin rights
/// and no privacy permission. The sensor is off by default, so `start()` switches
/// reporting on and `stop()` switches it back off.
///
/// These are private, undocumented sensor properties: a future macOS may change
/// them. Macs without the sensor simply produce no samples.
@MainActor
final class AccelerometerReader {
    static let usagePage = 0xFF00
    static let usage = 3
    static let reportIntervalMicroseconds = 10_000   // 100 Hz

    var onSample: ((AccelSample) -> Void)?
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private static let bufferSize = 128

    private(set) var isRunning = false

    /// Returns true if at least one accelerometer device was opened.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: Self.usagePage,
                                                kIOHIDPrimaryUsageKey: Self.usage] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        let found = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard !found.isEmpty else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        self.manager = manager
        Self.setDriverReporting(on: true)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in found where IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            Self.setDeviceReporting(device, on: true)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
            buffers.append(buffer)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, accelReportCallback, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            devices.append(device)
        }
        isRunning = !devices.isEmpty
        if !isRunning { stop() }
        return isRunning
    }

    func stop() {
        for device in devices {
            IOHIDDeviceRegisterInputReportCallback(device, buffers[0], Self.bufferSize, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            Self.setDeviceReporting(device, on: false)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if manager != nil { Self.setDriverReporting(on: false) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        devices.removeAll()
        buffers.forEach { $0.deallocate() }
        buffers.removeAll()
        manager = nil
        isRunning = false
    }

    fileprivate func handle(bytes: [UInt8]) {
        if let sample = AccelReportDecoder.decode(bytes) { onSample?(sample) }
    }

    /// Switches sensor reporting off. Called at launch in case a previous run was
    /// force-killed mid-storm and never got to clean up.
    static func resetSensorToOff() {
        setDriverReporting(on: false)
    }

    // MARK: Sensor power (off by default; restored to off on stop)

    private static func properties(on: Bool) -> [(String, Int)] {
        [("SensorPropertyReportingState", on ? 1 : 0),
         ("SensorPropertyPowerState", on ? 1 : 0),
         ("ReportInterval", on ? reportIntervalMicroseconds : 0)]
    }

    private static func setDeviceReporting(_ device: IOHIDDevice, on: Bool) {
        for (key, value) in properties(on: on) {
            IOHIDDeviceSetProperty(device, key as CFString, value as CFNumber)
        }
    }

    private static func setDriverReporting(on: Bool) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let page = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            let usage = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            if page == usagePage, usage == Self.usage {
                for (key, value) in properties(on: on) {
                    IORegistryEntrySetCFProperty(service, key as CFString, value as CFNumber)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}

private func accelReportCallback(
    context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex
) {
    guard let context, length > 0 else { return }
    // Copy into Sendable values before hopping isolation.
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    let address = UInt(bitPattern: context)
    // Scheduled on the main run loop, so this already runs on the main thread.
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
        Unmanaged<AccelerometerReader>.fromOpaque(pointer).takeUnretainedValue().handle(bytes: bytes)
    }
}
