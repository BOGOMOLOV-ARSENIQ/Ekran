import CoreGraphics
import CPrivate
import Foundation
import IOKit
import os

enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case redGain = 0x16
    case greenGain = 0x18
    case blueGain = 0x1A
    case inputSource = 0x60
    case volume = 0x62
    case mute = 0x8D
    case powerMode = 0xD6
}

/// DDC/CI channel to one external monitor.
/// All I2C traffic runs on a private serial queue; rapid writes (slider drags) are coalesced so only
/// the latest value per control is sent and the UI never waits for the slow bus.
final class DDCChannel {
    private enum Transport {
        case avService(CFTypeRef)   // Apple silicon
        case framebuffer(io_service_t)  // Intel
    }

    private struct WriteQueue {
        var pending: [UInt8: UInt16] = [:]
        var draining = false
    }

    private let transport: Transport
    private let queue: DispatchQueue
    private let writes = OSAllocatedUnfairLock(initialState: WriteQueue())

    private init(transport: Transport, label: String) {
        self.transport = transport
        queue = DispatchQueue(label: "app.ekran.ddc.\(label)", qos: .userInitiated)
    }

    deinit {
        if case let .framebuffer(service) = transport { IOObjectRelease(service) }
    }

    // MARK: Discovery

    /// Creates channels for external displays. Matching on Apple silicon uses the framebuffer registry path
    /// that CoreDisplay reports for each display, so identical monitors are never confused.
    static func discover(for displays: [Display]) -> [CGDirectDisplayID: DDCChannel] {
        let candidates = displays.filter { $0.kind == .physical && !$0.isBuiltin && !$0.hasAppleBrightness && !$0.settings.ddcDisabled }
        guard !candidates.isEmpty else { return [:] }
        var result: [CGDirectDisplayID: DDCChannel] = [:]
        #if arch(arm64)
        let services = appleSiliconServices()
        var unmatched = candidates
        for display in candidates {
            if let location = display.info["IODisplayLocation"] as? String, let service = services[location] {
                result[display.id] = DDCChannel(transport: .avService(service), label: "\(display.id)")
                unmatched.removeAll { $0 === display }
            }
        }
        // Fallback when CoreDisplay has no location: a single unmatched monitor and a single unused service.
        let used = Set(candidates.compactMap { $0.info["IODisplayLocation"] as? String })
        let spare = services.filter { !used.contains($0.key) }
        if unmatched.count == 1, spare.count == 1, let display = unmatched.first, let service = spare.first?.value {
            result[display.id] = DDCChannel(transport: .avService(service), label: "\(display.id)")
        }
        #else
        for display in candidates {
            let framebuffer = EKIntelFramebufferForDisplay(display.id)
            if framebuffer != IO_OBJECT_NULL {
                result[display.id] = DDCChannel(transport: .framebuffer(framebuffer), label: "\(display.id)")
            }
        }
        #endif
        return result
    }

    #if arch(arm64)
    private static func appleSiliconServices() -> [String: CFTypeRef] {
        var services: [String: CFTypeRef] = [:]
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return services
        }
        defer { IOObjectRelease(iterator) }

        var framebufferPath: String?
        var name = [CChar](repeating: 0, count: 128)
        var path = [CChar](repeating: 0, count: 1024)
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            switch String(cString: name) {
            case "AppleCLCD2", "IOMobileFramebufferShim":
                framebufferPath = IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS ? String(cString: path) : nil
            case "DCPAVServiceProxy":
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                if location == "External", let framebufferPath, let service = EKAVServiceCreate(entry) {
                    services[framebufferPath] = service
                }
            default:
                break
            }
        }
        return services
    }
    #endif

    // MARK: Public API

    /// Coalesced asynchronous write.
    func write(_ code: VCP, _ value: UInt16) {
        let shouldStart = writes.withLock { state in
            state.pending[code.rawValue] = value
            defer { state.draining = true }
            return !state.draining
        }
        guard shouldStart else { return }
        queue.async { [self] in
            while true {
                let next: (UInt8, UInt16)? = writes.withLock { state in
                    guard let item = state.pending.first else {
                        state.draining = false
                        return nil
                    }
                    state.pending.removeValue(forKey: item.key)
                    return (item.key, item.value)
                }
                guard case let (code, value)? = next else { return }
                if !setVCP(code, value) {
                    Log.ddc.error("DDC write 0x\(String(code, radix: 16)) failed")
                }
            }
        }
    }

    /// Asynchronous read; completion runs on the main queue.
    func read(_ code: VCP, completion: @escaping ((current: Int, maximum: Int)?) -> Void) {
        queue.async { [self] in
            let result = getVCP(code.rawValue)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func copyEDID() -> Data? {
        switch transport {
        case let .avService(service): EKAVServiceCopyEDID(service) as Data?
        case let .framebuffer(framebuffer): EKIntelCopyEDID(framebuffer) as Data?
        }
    }

    // MARK: Protocol

    private func setVCP(_ code: UInt8, _ value: UInt16) -> Bool {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        switch transport {
        case let .avService(service):
            var packet = body
            packet.append(body.reduce(0x6E ^ 0x51, ^))
            for _ in 0 ..< 3 {
                var ok = false
                for _ in 0 ..< 2 {   // monitors occasionally drop a single write
                    usleep(10_000)
                    ok = EKAVServiceWriteI2C(service, 0x37, 0x51, packet, UInt32(packet.count)) == kIOReturnSuccess || ok
                }
                if ok { return true }
                usleep(20_000)
            }
            return false
        case let .framebuffer(framebuffer):
            var packet: [UInt8] = [0x51] + body
            packet.append(packet.reduce(0x6E, ^))
            return EKIntelDDCRequest(framebuffer, packet, UInt32(packet.count), nil, 0)
        }
    }

    private func getVCP(_ code: UInt8) -> (current: Int, maximum: Int)? {
        var reply = [UInt8](repeating: 0, count: 11)
        switch transport {
        case let .avService(service):
            var packet: [UInt8] = [0x82, 0x01, code]
            packet.append(packet.reduce(0x6E, ^))
            for _ in 0 ..< 4 {
                for _ in 0 ..< 2 {
                    usleep(10_000)
                    _ = EKAVServiceWriteI2C(service, 0x37, 0x51, packet, UInt32(packet.count))
                }
                usleep(50_000)
                if EKAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                   let parsed = Self.parseReply(reply, code: code, verifyChecksum: true) {
                    return parsed
                }
                usleep(20_000)
            }
            return nil
        case let .framebuffer(framebuffer):
            var packet: [UInt8] = [0x51, 0x82, 0x01, code]
            packet.append(packet.reduce(0x6E, ^))
            for _ in 0 ..< 3 {
                if EKIntelDDCRequest(framebuffer, packet, UInt32(packet.count), &reply, UInt32(reply.count)),
                   let parsed = Self.parseReply(reply, code: code, verifyChecksum: false) {
                    return parsed
                }
                usleep(30_000)
            }
            return nil
        }
    }

    private static func parseReply(_ reply: [UInt8], code: UInt8, verifyChecksum: Bool) -> (current: Int, maximum: Int)? {
        if verifyChecksum, reply[0 ..< 10].reduce(UInt8(0x50), ^) != reply[10] { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        return maximum > 0 ? (current, maximum) : nil
    }
}

enum DDCInput: UInt16, CaseIterable {
    case vga1 = 0x01, dvi1 = 0x03, dvi2 = 0x04, displayPort1 = 0x0F, displayPort2 = 0x10
    case hdmi1 = 0x11, hdmi2 = 0x12, usbC = 0x1B

    var title: String {
        switch self {
        case .vga1: "VGA"
        case .dvi1: "DVI-1"
        case .dvi2: "DVI-2"
        case .displayPort1: "DisplayPort-1"
        case .displayPort2: "DisplayPort-2"
        case .hdmi1: "HDMI-1"
        case .hdmi2: "HDMI-2"
        case .usbC: "USB-C"
        }
    }
}
