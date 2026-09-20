import CoreGraphics
import CPrivate

/// While every physical display sleeps WindowServer defers reconfiguration (virtual displays are not even removed),
/// so transactions stall. Virtual displays never sleep and are ignored.
var areDisplaysAsleep: Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
    let physical = ids.prefix(Int(count)).filter { id in
        let vendor = CGDisplayVendorNumber(id)
        return vendor != EkranVendor.scaling && vendor != EkranVendor.virtualScreen
            && !((EKCopyDisplayInfo(id) as? [String: Any])?["kCGDisplayIsVirtualDevice"] as? Bool ?? false)
    }
    return !physical.isEmpty && physical.allSatisfy { CGDisplayIsAsleep($0) != 0 }
}

/// One transaction of display configuration changes. Returns false (and cancels) if `body` fails.
/// Never submit a transaction that changes nothing (for example the mode a display already uses):
/// WindowServer then waits for a reconfiguration that never comes and blocks for 10 seconds (CGError 1014).
/// Nothing is submitted while the displays sleep; the wake notification triggers a new reconciliation.
@discardableResult
func configureDisplays(_ option: CGConfigureOption = .permanently, _ body: (CGDisplayConfigRef) -> Bool) -> Bool {
    guard !areDisplaysAsleep else {
        Log.display.info("display configuration postponed: displays are asleep")
        return false
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    guard body(config) else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    let started = CFAbsoluteTimeGetCurrent()
    let result = CGCompleteDisplayConfiguration(config, option)
    let elapsed = CFAbsoluteTimeGetCurrent() - started
    if result != .success { Log.display.error("display configuration failed: CGError \(result.rawValue) after \(elapsed, format: .fixed(precision: 2))s") }
    if elapsed > 1 { Log.display.error("slow display configuration: \(elapsed, format: .fixed(precision: 2))s") }
    return result == .success
}

struct DisplayModeInfo {
    private static let nativeFlag: UInt32 = 0x0200_0000
    private static let defaultFlag: UInt32 = 0x0000_0004

    let mode: CGDisplayMode
    let spec: ModeSpec
    let isNative: Bool
    let isDefault: Bool

    init(_ mode: CGDisplayMode) {
        self.mode = mode
        spec = ModeSpec(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                        pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
        isNative = mode.ioFlags & Self.nativeFlag != 0
        isDefault = mode.ioFlags & Self.defaultFlag != 0
    }

    var width: Int { spec.width }
    var height: Int { spec.height }
    var isHiDPI: Bool { spec.isHiDPI }
    var refreshRate: Double { spec.refreshRate }

    /// Same resolution ignoring refresh rate.
    func hasSameSize(as other: ModeSpec) -> Bool {
        spec.width == other.width && spec.height == other.height
            && spec.pixelWidth == other.pixelWidth && spec.pixelHeight == other.pixelHeight
    }
}

extension ModeSpec {
    var sizeTitle: String { "\(width)×\(height)" }

    var refreshTitle: String {
        refreshRate > 0 ? "\(refreshRate.rounded() == refreshRate ? String(Int(refreshRate)) : String(format: "%.2f", refreshRate)) Гц" : "—"
    }

    func matches(_ other: ModeSpec) -> Bool {
        width == other.width && height == other.height && pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight && abs(refreshRate - other.refreshRate) < 0.5
    }
}

extension Display {
    /// Every mode including HiDPI ones (CoreGraphics omits those unless the duplicates option is passed).
    func modes() -> [DisplayModeInfo] {
        if let modeCache { return modeCache }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        var seen = Set<ModeSpec>()
        let result = modes
            .filter { $0.isUsableForDesktopGUI() }
            .map(DisplayModeInfo.init)
            .filter { seen.insert($0.spec).inserted }
        if !result.isEmpty { modeCache = result }
        return result
    }

    var currentMode: DisplayModeInfo? {
        CGDisplayCopyDisplayMode(id).map(DisplayModeInfo.init)
    }

    /// Native panel resolution in pixels.
    var nativePixelSize: (width: Int, height: Int) {
        let all = modes()
        let candidates = all.filter(\.isNative).isEmpty ? all : all.filter(\.isNative)
        let best = candidates.max { $0.spec.pixelWidth * $0.spec.pixelHeight < $1.spec.pixelWidth * $1.spec.pixelHeight }
        if let best { return (best.spec.pixelWidth, best.spec.pixelHeight) }
        return (CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id))
    }

    /// Highest refresh rate available at native resolution (60 when unknown or variable).
    var nativeRefreshRate: Double {
        let native = nativePixelSize
        let rates = modes().filter { $0.spec.pixelWidth == native.width && $0.spec.pixelHeight == native.height }.map(\.refreshRate)
        let best = rates.max() ?? 0
        return best >= 24 ? best : 60
    }

    @discardableResult
    func setMode(_ mode: DisplayModeInfo, option: CGConfigureOption = .permanently) -> Bool {
        if let current = currentMode, current.spec.matches(mode.spec) { return true }
        return configureDisplays(option) { CGConfigureDisplayWithDisplayMode($0, id, mode.mode, nil) == .success }
    }

    /// Finds the best available mode for a saved spec (exact refresh rate when possible).
    func mode(matching spec: ModeSpec) -> DisplayModeInfo? {
        let all = modes()
        return all.first { $0.spec.matches(spec) }
            ?? all.filter { $0.hasSameSize(as: spec) }.min { abs($0.refreshRate - spec.refreshRate) < abs($1.refreshRate - spec.refreshRate) }
    }
}

/// WindowServer applies the stored (or a default) configuration whenever the set of connected displays changes,
/// which can silently reset the resolution of unrelated displays. Around topology changes Ekran causes itself
/// (virtual displays, disconnects) the other displays' modes are remembered and put back.
struct ModeSnapshot {
    private let modes: [CGDirectDisplayID: ModeSpec]

    init(excluding excluded: Set<CGDirectDisplayID> = []) {
        var modes: [CGDirectDisplayID: ModeSpec] = [:]
        for display in DisplayManager.shared.physical where display.isArranged && !excluded.contains(display.id) {
            if let mode = display.currentMode { modes[display.id] = mode.spec }
        }
        self.modes = modes
    }

    /// Checks twice: once the reconfiguration has settled and again a little later for slow external monitors.
    func restoreAfterTopologyChange() {
        guard !modes.isEmpty else { return }
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { restore() }
        }
    }

    private func restore() {
        for (id, spec) in modes {
            guard let display = DisplayManager.shared.display(id: id), display.isArranged, !display.settings.scalingEnabled,
                  let current = display.currentMode, !current.spec.matches(spec),
                  let mode = display.mode(matching: spec)
            else { continue }
            Log.display.info("restoring \(display.name) to \(spec.sizeTitle) after a topology change")
            display.setMode(mode)
        }
    }
}
