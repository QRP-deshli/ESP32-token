// pico-vhid - virtual FIDO HID device for ctaphid_serial_bridge.py on macOS.
//
// Creates a HID device with the standard FIDO report descriptor through IOHIDUserDevice (macOS 10.15+), then moves
// 64-byte reports between it and the bridge (the helper protocol in desktop/common/virtual_hid.py):
//   - output reports from the OS (browser -> token) are written to stdout, 64 bytes each, no report ID
//   - input reports read from stdin (token -> browser), 64 bytes each, are handed to the OS
//   - log lines go to stderr; the helper exits when stdin is closed
//
//   pico-vhid --name "Pico FIDO2 (serial bridge)" --vid 0x1d50 --pid 0x619b
//   pico-vhid --check     only check that the device can be created (exit 0) or say why not (exit 1)
//
// Creating the device needs the entitlement com.apple.developer.hid.virtual.device (see ../virtual-hid.md).

import Foundation
import IOKit
import IOKit.hid

let reportLen = 64

// Standard FIDO HID report descriptor, same bytes as FIDO_REPORT_DESC in desktop/common/virtual_hid.py.
let fidoReportDescriptor: [UInt8] = [
    0x06, 0xD0, 0xF1,        // Usage Page (FIDO Alliance)
    0x09, 0x01,              // Usage (U2F/CTAP HID Authenticator Device)
    0xA1, 0x01,              // Collection (Application)
    0x09, 0x20,              //   Usage (Input Report Data)
    0x15, 0x00,              //   Logical Minimum (0)
    0x26, 0xFF, 0x00,        //   Logical Maximum (255)
    0x75, 0x08,              //   Report Size (8)
    0x95, 0x40,              //   Report Count (64)
    0x81, 0x02,              //   Input (Data,Var,Abs)
    0x09, 0x21,              //   Usage (Output Report Data)
    0x15, 0x00,
    0x26, 0xFF, 0x00,
    0x75, 0x08,
    0x95, 0x40,
    0x91, 0x02,              //   Output (Data,Var,Abs)
    0xC0,                    // End Collection
]

func log(_ msg: String) {
    FileHandle.standardError.write(("pico-vhid: " + msg + "\n").data(using: .utf8)!)
}

func fail(_ msg: String) -> Never {
    log(msg)
    exit(1)
}

// --- arguments ------------------------------------------------------------------------------------------------------
var name = "Pico FIDO2 (serial bridge)"
var vid = 0x1D50
var pid = 0x619B
var checkOnly = false
var argv = CommandLine.arguments.dropFirst().makeIterator()
func number(_ s: String?) -> Int {
    guard let s = s else { fail("missing value") }
    let v = s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
    guard let n = v else { fail("not a number: \(s)") }
    return n
}
while let a = argv.next() {
    switch a {
    case "--name": name = argv.next() ?? name
    case "--vid": vid = number(argv.next())
    case "--pid": pid = number(argv.next())
    case "--check": checkOnly = true
    case "-h", "--help":
        print("usage: pico-vhid [--name NAME] [--vid 0xVVVV] [--pid 0xPPPP] | --check  (started by ctaphid_serial_bridge.py)")
        exit(0)
    default: fail("unknown argument \(a)")
    }
}

// --- the device -----------------------------------------------------------------------------------------------------
let properties: [String: Any] = [
    kIOHIDReportDescriptorKey: Data(fidoReportDescriptor),
    kIOHIDVendorIDKey: vid,
    kIOHIDProductIDKey: pid,
    kIOHIDProductKey: name,
    kIOHIDManufacturerKey: "ctaphid-serial-bridge",
    kIOHIDTransportKey: "USB",
    kIOHIDPrimaryUsagePageKey: 0xF1D0,
    kIOHIDPrimaryUsageKey: 0x01,
    kIOHIDMaxInputReportSizeKey: reportLen,
    kIOHIDMaxOutputReportSizeKey: reportLen,
]

guard let device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else {
    fail("""
        cannot create the virtual HID device. This binary needs the entitlement \
        com.apple.developer.hid.virtual.device and a signature that macOS accepts for it \
        (see desktop/mac/virtual-hid.md).
        """)
}

if checkOnly {
    log("OK: the virtual HID device can be created")
    exit(0)                                  // the device goes away with the process
}

let stdout = FileHandle.standardOutput
let queue = DispatchQueue(label: "pico-vhid")

// OS -> token: output reports (and SET_REPORT of type output) go to the bridge
IOHIDUserDeviceRegisterSetReportBlock(device) { type, reportID, report, length in
    guard type == kIOHIDReportTypeOutput else { return kIOReturnUnsupported }
    var bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
    if bytes.count == reportLen + 1 && reportID == 0 && bytes[0] == 0 { bytes.removeFirst() }
    guard bytes.count == reportLen else {
        log("ignoring output report of \(bytes.count) bytes")
        return kIOReturnBadArgument
    }
    stdout.write(Data(bytes))
    return kIOReturnSuccess
}
IOHIDUserDeviceRegisterGetReportBlock(device) { _, _, _, _ in kIOReturnUnsupported }
IOHIDUserDeviceSetCancelHandler(device) { exit(0) }
IOHIDUserDeviceSetDispatchQueue(device, queue)
IOHIDUserDeviceActivate(device)
log(String(format: "virtual FIDO device %04x:%04x active", vid, pid))

// token -> OS: read 64-byte input reports from stdin until it is closed
let reader = Thread {
    var buf = [UInt8](repeating: 0, count: reportLen)
    while true {
        var got = 0
        while got < reportLen {
            let n = buf.withUnsafeMutableBytes { read(0, $0.baseAddress! + got, reportLen - got) }
            if n <= 0 {
                IOHIDUserDeviceCancel(device)        // the cancel handler exits
                return
            }
            got += n
        }
        let report = buf
        queue.async {
            let rc = report.withUnsafeBufferPointer {
                IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), $0.baseAddress!, reportLen)
            }
            if rc != kIOReturnSuccess { log(String(format: "handle report failed: 0x%08x", rc)) }
        }
    }
}
reader.start()
dispatchMain()
