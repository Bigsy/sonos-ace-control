import Foundation
import IOKit.hid

// Read-only probe, restricted to the observed Sonos Ace Ultra USB VID/PID.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 14552, kIOHIDProductIDKey: 22321] as CFDictionary)
guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
    print("No Sonos USB HID device found."); exit(1)
}
for device in devices {
    print("Device: \(IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) ?? "unknown" as CFString)")
    let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print(String(format: "Nonexclusive open: 0x%08x", result))
    guard result == kIOReturnSuccess else { continue }
    defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    for report in [0x80, 0x81, 0x83] {
        var bytes = [UInt8](repeating: 0, count: 33)
        bytes[0] = UInt8(report)
        var length = bytes.count
        let status = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(report), &bytes, &length)
        print(String(format: "Feature 0x%02x GET status=0x%08x length=%d", report, status, length))
        if status == kIOReturnSuccess {
            print(bytes.prefix(length).map { String(format: "%02x", $0) }.joined(separator: " "))
        }
    }
}
