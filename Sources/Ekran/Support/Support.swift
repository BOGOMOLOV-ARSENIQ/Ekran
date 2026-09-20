import AppKit
import os

enum Log {
    private static let subsystem = "app.ekran.Ekran"
    static let general = Logger(subsystem: subsystem, category: "general")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let ddc = Logger(subsystem: subsystem, category: "ddc")
    static let scaling = Logger(subsystem: subsystem, category: "scaling")
    static let automation = Logger(subsystem: subsystem, category: "automation")
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? kCGNullDirectDisplay
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension NSImage {
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

/// Runs the last scheduled block after `delay`; earlier pending blocks are dropped.
final class Debouncer {
    private let delay: TimeInterval
    private var item: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func schedule(_ block: @escaping () -> Void) {
        item?.cancel()
        let item = DispatchWorkItem(block: block)
        self.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        item?.cancel()
        item = nil
    }
}

/// Stable 32-bit FNV-1a hash (Swift's Hasher is randomly seeded per launch).
func stableHash(_ string: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for byte in string.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16_777_619
    }
    return hash
}

func gcd(_ a: Int, _ b: Int) -> Int {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

extension String {
    /// "Dell U2720Q" → "Dell U2720Q"; trims the noise some EDIDs carry.
    var trimmedDisplayName: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
}
