import AppKit
import CPrivate

struct ScaleOption: Hashable, Comparable {
    let width: Int
    let height: Int

    static func < (lhs: ScaleOption, rhs: ScaleOption) -> Bool { lhs.width < rhs.width }

    var title: String { "\(width)×\(height)" }
}

/// Flexible HiDPI scaling for any display.
///
/// When macOS itself offers a HiDPI mode of the chosen size, that mode is selected directly: the display pipeline
/// scales in hardware, the hardware cursor and full refresh rate stay, and no virtual display exists. Other sizes
/// use a hidden virtual display that renders the desktop at 2× and that the physical display mirrors.
/// Everything is expressed as desired state (settings) and `reconcile()` converges the system to it after any
/// display event; configuration is app-scoped, so quitting or crashing restores the original setup.
final class ScalingController {
    static let shared = ScalingController()

    /// Largest backing framebuffer edge we create (8K class GPUs handle this comfortably).
    private static let maxBackingPixels = 8192

    private final class Session {
        let key: String
        let backend: EKVirtualDisplay
        let options: [ScaleOption]
        let hiDPI: Bool
        var previousMode: ModeSpec?
        /// Where the physical display sat before the backend appeared (WindowServer may shuffle displays meanwhile).
        var homeOrigin: CGPoint = .zero
        var originPlaced = false
        var appliedWidth: Int?
        var attempts = 0
        var nativeModeRequested = false

        init(key: String, backend: EKVirtualDisplay, options: [ScaleOption], hiDPI: Bool) {
            self.key = key
            self.backend = backend
            self.options = options
            self.hiDPI = hiDPI
        }

        var backendID: CGDirectDisplayID { backend.displayID }
    }

    private struct NativeSession {
        var previousMode: ModeSpec?
    }

    /// Modes WindowServer generates for a display while it mirrors another; they cannot be selected directly.
    private static let mirrorOnlyFlag: UInt32 = 0x0020_0000

    private var sessions: [String: Session] = [:]
    private var nativeSessions: [String: NativeSession] = [:]
    private var startFailures: [String: Int] = [:]
    private let retry = Debouncer(delay: 0.35)

    var isSupported: Bool { EKVirtualDisplay.isSupported() }

    // MARK: Queries

    static func ladder(native: (width: Int, height: Int), custom: [Int] = []) -> [ScaleOption] {
        let (w, h) = native
        guard w > 0, h > 0 else { return [] }
        let divisor = gcd(w, h)
        let aspect = (width: w / divisor, height: h / divisor)

        /// Ladder steps snap to exact aspect multiples; a width the user typed is kept as is (height rounded).
        func option(width target: Int, exact: Bool = false) -> ScaleOption? {
            let width: Int
            let height: Int
            if exact {
                width = target
                height = Int((Double(width) * Double(h) / Double(w)).rounded())
            } else if aspect.width <= 64 {
                let k = max(1, Int((Double(target) / Double(aspect.width)).rounded()))
                width = k * aspect.width
                height = k * aspect.height
            } else {
                width = max(2, target / 2 * 2)
                height = Int((Double(width) * Double(h) / Double(w)).rounded())
            }
            guard width >= 640, width * 2 <= maxBackingPixels, height * 2 <= maxBackingPixels else { return nil }
            return ScaleOption(width: width, height: height)
        }

        var fractions = stride(from: 0.5, through: 1.0001, by: 0.025).map { $0 }
        fractions += [1.1, 1.25, 1.5]
        var options = Set(fractions.compactMap { option(width: Int(Double(w) * $0)) })
        options.formUnion(custom.compactMap { option(width: $0, exact: true) })
        return options.sorted()
    }

    func options(for display: Display) -> [ScaleOption] {
        let base = sessions[display.key]?.options
            ?? Self.ladder(native: display.nativePixelSize, custom: display.settings.customScalingWidths)
        return Array(Set(base).union(nativeOptions(for: display))).sorted()
    }

    /// HiDPI sizes macOS offers natively for this display with the panel's aspect ratio.
    func nativeOptions(for display: Display) -> [ScaleOption] {
        let native = display.nativePixelSize
        guard native.width > 0, native.height > 0 else { return [] }
        let aspect = Double(native.width) / Double(native.height)
        let sizes = display.modes().filter {
            $0.isHiDPI && $0.mode.ioFlags & Self.mirrorOnlyFlag == 0 && $0.width >= 640
                && abs(Double($0.width) / Double($0.height) - aspect) / aspect < 0.01
        }
        return Set(sizes.map { ScaleOption(width: $0.width, height: $0.height) }).sorted()
    }

    /// The HiDPI mode macOS offers at exactly this size, if any (preferring the current refresh rate).
    func nativeMode(for display: Display, option: ScaleOption) -> DisplayModeInfo? {
        guard display.settings.scalingHiDPI else { return nil }
        let current = display.currentMode?.spec
        // While mirroring, the display lists the mirrored size as its current mode; that is not a real mode.
        let mirroredSpec = display.mirrorSource != kCGNullDirectDisplay ? current : nil
        let rate = current?.refreshRate ?? display.nativeRefreshRate
        return display.modes()
            .filter {
                $0.width == option.width && $0.height == option.height
                    && $0.spec.pixelWidth == option.width * 2 && $0.spec.pixelHeight == option.height * 2
                    && $0.mode.ioFlags & Self.mirrorOnlyFlag == 0 && $0.spec != mirroredSpec
            }
            .min { abs($0.refreshRate - rate) < abs($1.refreshRate - rate) }
    }

    func isNative(_ display: Display) -> Bool {
        nativeSessions[display.key] != nil
    }

    /// The "looks like" size that corresponds to the sharpest 2:1 mapping onto the panel.
    func crispOption(for display: Display) -> ScaleOption? {
        let native = display.nativePixelSize
        return options(for: display).first { $0.width * 2 == native.width }
    }

    func isEnabled(_ display: Display) -> Bool {
        display.settings.scalingEnabled
    }

    func isActive(_ display: Display) -> Bool {
        if nativeSessions[display.key] != nil { return display.currentMode?.isHiDPI ?? false }
        guard let session = sessions[display.key] else { return false }
        return CGDisplayMirrorsDisplay(display.id) == session.backendID
    }

    func backendID(for display: Display) -> CGDirectDisplayID? {
        sessions[display.key]?.backendID
    }

    func physicalDisplay(forBackend id: CGDirectDisplayID) -> Display? {
        guard let session = sessions.values.first(where: { $0.backendID == id }) else { return nil }
        return DisplayManager.shared.display(key: session.key)
    }

    func isBackend(_ id: CGDirectDisplayID) -> Bool {
        sessions.values.contains { $0.backendID == id }
    }

    func currentOption(for display: Display) -> ScaleOption? {
        if nativeSessions[display.key] != nil, let mode = display.currentMode, mode.isHiDPI {
            return ScaleOption(width: mode.width, height: mode.height)
        }
        guard let session = sessions[display.key], let mode = CGDisplayCopyDisplayMode(session.backendID) else {
            return display.settings.scalingWidth.flatMap { width in options(for: display).first { $0.width == width } }
        }
        return ScaleOption(width: mode.width, height: mode.height)
    }

    // MARK: Commands

    func setEnabled(_ enabled: Bool, for display: Display) {
        guard isSupported, display.kind == .physical else { return }
        let fallbackWidth = display.settings.scalingWidth == nil ? defaultOption(for: display)?.width : nil
        display.updateSettings { settings in
            settings.scalingEnabled = enabled
            if enabled, settings.scalingWidth == nil { settings.scalingWidth = fallbackWidth }
        }
        reconcile()
    }

    func select(_ option: ScaleOption, for display: Display) {
        display.updateSettings {
            $0.scalingWidth = option.width
            $0.scalingEnabled = true
        }
        if let session = sessions[display.key], !session.options.contains(option), nativeMode(for: display, option: option) == nil {
            restart(display)
        } else {
            reconcile()
        }
        OSD.shared.show(.text(option.title, symbol: "rectangle.arrowtriangle.2.inward"), on: display)
    }

    func addCustomWidth(_ width: Int, for display: Display) {
        display.updateSettings {
            if !$0.customScalingWidths.contains(width) { $0.customScalingWidths.append(width) }
        }
        let native = display.nativePixelSize
        if let option = Self.ladder(native: native, custom: [width]).first(where: { $0.width == width }) {
            select(option, for: display)
        }
    }

    func setHiDPI(_ hiDPI: Bool, for display: Display) {
        display.updateSettings { $0.scalingHiDPI = hiDPI }
        restart(display)
    }

    /// Positive steps make the interface larger (fewer points on screen).
    func step(_ display: Display, by steps: Int) {
        let options = options(for: display)
        guard !options.isEmpty else { return }
        let current = currentOption(for: display) ?? defaultOption(for: display) ?? options[options.count / 2]
        let index = options.firstIndex { $0.width >= current.width } ?? options.count - 1
        let next = options[(index - steps).clamped(to: 0 ... options.count - 1)]
        if next != current || !isEnabled(display) { select(next, for: display) }
    }

    private func defaultOption(for display: Display) -> ScaleOption? {
        let options = options(for: display)
        // Prefer the current "looks like" size so enabling scaling does not change the layout.
        if let mode = display.currentMode, let same = options.first(where: { $0.width == mode.width && $0.height == mode.height }) {
            return same
        }
        // Otherwise about 150% of the crisp 2× size: comfortable text on typical desktop monitors.
        let native = display.nativePixelSize
        let target = Int(Double(native.width) * 0.75)
        return options.min { abs($0.width - target) < abs($1.width - target) }
    }

    private func restart(_ display: Display) {
        if let session = sessions.removeValue(forKey: display.key) {
            // Keep the original mode so disabling scaling later still returns to it.
            nativeSessions[display.key] = nil
            end(session, physical: display, restoreMode: false)
            pendingPreviousModes[display.key] = session.previousMode
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reconcile() }
    }

    /// Original modes carried over while a display switches between the native and the mirroring method.
    private var pendingPreviousModes: [String: ModeSpec?] = [:]

    private func desiredOption(for display: Display) -> ScaleOption? {
        guard let width = display.settings.scalingWidth ?? defaultOption(for: display)?.width else { return nil }
        let candidates = Self.ladder(native: display.nativePixelSize, custom: display.settings.customScalingWidths)
            + nativeOptions(for: display)
        return candidates.min { abs($0.width - width) < abs($1.width - width) }
    }

    private func applyNative(_ option: ScaleOption, mode: DisplayModeInfo, to display: Display) {
        display.modeCache = nil
        if nativeSessions[display.key] == nil {
            let carried = pendingPreviousModes.removeValue(forKey: display.key)
            nativeSessions[display.key] = NativeSession(previousMode: carried ?? display.currentMode?.spec)
        }
        if display.currentMode?.spec.matches(mode.spec) != true {
            display.setMode(mode, option: .forAppOnly)
            Log.scaling.info("\(display.name) uses the native HiDPI mode \(option.title)")
        }
        if display.settings.scalingWidth != option.width {
            display.updateSettings { $0.scalingWidth = option.width }
        }
    }

    // MARK: Reconciliation

    func reconcile() {
        guard isSupported else { return }
        let physical = DisplayManager.shared.physical

        for (key, session) in sessions {
            let display = physical.first { $0.key == key }
            if display == nil || display?.settings.scalingEnabled == false {
                sessions[key] = nil
                end(session, physical: display)
            }
        }
        for (key, native) in nativeSessions {
            let display = physical.first { $0.key == key }
            guard display == nil || display?.settings.scalingEnabled == false else { continue }
            nativeSessions[key] = nil
            if let display, let previous = native.previousMode.flatMap({ display.mode(matching: $0) }) {
                display.setMode(previous, option: .forAppOnly)
            }
        }

        var pending = false
        for display in physical where display.settings.scalingEnabled {
            if let option = desiredOption(for: display), nativeMode(for: display, option: option) != nil {
                if let session = sessions.removeValue(forKey: display.key) {
                    // Leave the mirroring backend first; the native mode is selected once the display is standalone.
                    pendingPreviousModes[display.key] = session.previousMode
                    end(session, physical: display, restoreMode: false)
                    pending = true
                } else {
                    display.modeCache = nil  // drop modes listed while the display was still mirroring
                    if let mode = nativeMode(for: display, option: option) {
                        applyNative(option, mode: mode, to: display)
                    }
                }
                continue
            }
            if let native = nativeSessions.removeValue(forKey: display.key) {
                pendingPreviousModes[display.key] = native.previousMode
            }
            guard let session = sessions[display.key] ?? start(display) else {
                // Recreating a virtual display right after destroying one with the same identity can fail briefly.
                let failures = startFailures[display.key, default: 0] + 1
                startFailures[display.key] = failures
                if failures < 20 { pending = true }
                continue
            }
            startFailures[display.key] = nil
            if !establish(session, physical: display) { pending = true }
        }
        // During display sleep nothing can be configured; DisplayManager reconciles again on wake.
        if pending, !areDisplaysAsleep {
            retry.schedule { [weak self] in self?.reconcile() }
        }
    }

    func teardownAll() {
        for (key, session) in sessions {
            end(session, physical: DisplayManager.shared.display(key: key), releaseDelay: 0)
        }
        sessions.removeAll()
    }

    private func start(_ display: Display) -> Session? {
        let native = display.nativePixelSize
        let hiDPI = display.settings.scalingHiDPI
        let options = Self.ladder(native: native, custom: display.settings.customScalingWidths)
        guard let largest = options.last else { return nil }
        let factor = hiDPI ? 2 : 1
        let refreshRate = display.nativeRefreshRate

        var size = display.physicalSizeMillimeters
        if size == .zero {
            size = CGSize(width: Double(native.width) / 110 * 25.4, height: Double(native.height) / 110 * 25.4)
        }
        let hash = stableHash(display.key)
        let key = display.key
        let snapshot = ModeSnapshot(excluding: [display.id])
        let homeOrigin = CGDisplayBounds(display.id).origin
        guard let backend = EKVirtualDisplay(
            name: "\(display.name) (HiDPI)",
            maxPixelsWide: UInt32(largest.width * factor),
            maxPixelsHigh: UInt32(options.map(\.height).max()! * factor),
            sizeInMillimeters: size,
            vendorID: EkranVendor.scaling,
            productID: hash & 0xFFFF,
            serialNumber: hash,
            chromaticity: display.chromaticity,
            terminationHandler: { [weak self] in
                DispatchQueue.main.async { self?.backendTerminated(key) }
            })
        else {
            Log.scaling.error("virtual display creation failed for \(display.name)")
            return nil
        }

        // With hiDPI enabled a mode W×H becomes a selectable "looks like W×H" mode backed by 2W×2H pixels,
        // provided that fits into maxPixels. (The W/2×H/2 variant it also creates is a hidden duplicate.)
        let modes = options.map {
            EKVirtualMode(width: UInt32($0.width), height: UInt32($0.height), refreshRate: refreshRate)
        }
        let applied = modes.withUnsafeBufferPointer { backend.applyModes($0.baseAddress!, count: UInt($0.count), hiDPI: hiDPI) }
        guard applied else {
            Log.scaling.error("applying \(modes.count) modes failed for \(display.name)")
            return nil
        }

        let session = Session(key: key, backend: backend, options: options, hiDPI: hiDPI)
        if let carried = pendingPreviousModes.removeValue(forKey: key) {
            session.previousMode = carried
        } else {
            session.previousMode = display.currentMode?.spec
        }
        session.homeOrigin = homeOrigin
        sessions[key] = session
        snapshot.restoreAfterTopologyChange()
        Log.scaling.info("backend \(backend.displayID) created for \(display.name), \(options.count) sizes @\(refreshRate)Hz")
        return session
    }

    /// Returns true when the physical display shows the backend at the desired size.
    private func establish(_ session: Session, physical: Display) -> Bool {
        let backendID = session.backendID
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        // Only reconfigure once WindowServer has finished adding the backend (DisplayManager saw it);
        // doing it earlier blocks the main thread until a WindowServer timeout.
        guard DisplayManager.shared.display(id: backendID) != nil, CGDisplayIsOnline(backendID) != 0,
              let modes = CGDisplayCopyAllDisplayModes(backendID, options) as? [CGDisplayMode], !modes.isEmpty
        else {
            session.attempts += 1
            if session.attempts > 60 {
                Log.scaling.error("backend \(backendID) never came online")
                return true
            }
            return false
        }

        let factor = session.hiDPI ? 2 : 1
        let desiredWidth = physical.settings.scalingWidth ?? defaultOption(for: physical)?.width ?? session.options[0].width
        guard let option = session.options.min(by: { abs($0.width - desiredWidth) < abs($1.width - desiredWidth) }) else { return true }
        guard let target = modes.first(where: {
            $0.isUsableForDesktopGUI() && $0.width == option.width && $0.height == option.height && $0.pixelWidth == option.width * factor
        }) else {
            Log.scaling.error("backend has no mode \(option.title)@\(factor)x; available: \(modes.map { "\($0.width)x\($0.height)/\($0.pixelWidth)" })")
            return true
        }

        let current = CGDisplayCopyDisplayMode(backendID)
        let mirrored = CGDisplayMirrorsDisplay(physical.id) == backendID

        // Size changed elsewhere (System Settings): adopt it instead of fighting the user.
        if mirrored, let current, let applied = session.appliedWidth, current.width != applied,
           current.pixelWidth == current.width * factor,
           session.options.contains(where: { $0.width == current.width && $0.height == current.height }) {
            session.appliedWidth = current.width
            physical.updateSettings { $0.scalingWidth = current.width }
            return true
        }

        let needsMode = current.map { $0.width != option.width || $0.pixelWidth != option.width * factor } ?? true
        guard needsMode || !mirrored else {
            session.appliedWidth = option.width
            session.attempts = 0
            placeAtHome(session)
            return true
        }

        let physicalOrigin = session.homeOrigin
        if !mirrored, !session.nativeModeRequested, let nativeMode = nativeMode(for: physical), let current = physical.currentMode,
           current.spec.pixelWidth != nativeMode.spec.pixelWidth || current.spec.pixelHeight != nativeMode.spec.pixelHeight {
            // Drive the panel at its native pixel count so only one resampling step happens.
            // (Changing the mode in the same transaction as mirroring is rejected by WindowServer.)
            session.nativeModeRequested = true
            if physical.setMode(nativeMode, option: .forAppOnly) { return false }
        }
        let ok = configureDisplays(.forAppOnly) { config in
            if needsMode {
                let error = CGConfigureDisplayWithDisplayMode(config, backendID, target, nil)
                guard error == .success else {
                    Log.scaling.error("backend mode change failed: CGError \(error.rawValue)")
                    return false
                }
            }
            if !mirrored {
                let error = CGConfigureDisplayMirrorOfDisplay(config, physical.id, backendID)
                guard error == .success else {
                    Log.scaling.error("mirroring failed: CGError \(error.rawValue)")
                    return false
                }
                CGConfigureDisplayOrigin(config, backendID, Int32(physicalOrigin.x), Int32(physicalOrigin.y))
            }
            return true
        }
        guard ok else {
            session.attempts += 1
            return session.attempts > 60
        }
        session.appliedWidth = option.width
        session.attempts = 0
        if physical.settings.scalingWidth != option.width {
            physical.updateSettings { $0.scalingWidth = option.width }
        }
        Log.scaling.info("\(physical.name) now looks like \(option.title)")
        return true
    }

    /// WindowServer anchors a new mirror set where the backend happened to appear and ignores an origin set in the
    /// mirroring transaction, so the display is moved back to where the monitor was in a separate step (once, so a
    /// later manual rearrangement is respected).
    private func placeAtHome(_ session: Session) {
        guard !session.originPlaced else { return }
        session.originPlaced = true
        let home = session.homeOrigin
        guard CGDisplayBounds(session.backendID).origin != home else { return }
        configureDisplays(.forAppOnly) { CGConfigureDisplayOrigin($0, session.backendID, Int32(home.x), Int32(home.y)) == .success }
    }

    /// Mode that drives the panel at its native pixel count, keeping the current refresh rate when possible.
    private func nativeMode(for display: Display) -> DisplayModeInfo? {
        let native = display.nativePixelSize
        let rate = display.currentMode?.refreshRate ?? display.nativeRefreshRate
        let candidates = display.modes().filter { $0.spec.pixelWidth == native.width && $0.spec.pixelHeight == native.height }
        return candidates.min {
            (abs($0.refreshRate - rate), $0.isHiDPI ? 0 : 1) < (abs($1.refreshRate - rate), $1.isHiDPI ? 0 : 1)
        }
    }

    private func end(_ session: Session, physical: Display?, releaseDelay: TimeInterval = 0.3, restoreMode: Bool = true) {
        let snapshot = ModeSnapshot(excluding: physical.map { [$0.id] } ?? [])
        defer { if releaseDelay > 0 { snapshot.restoreAfterTopologyChange() } }
        if let physical, physical.isOnline, CGDisplayMirrorsDisplay(physical.id) == session.backendID {
            let origin = CGDisplayBounds(session.backendID).origin
            configureDisplays(.forAppOnly) { config in
                CGConfigureDisplayMirrorOfDisplay(config, physical.id, kCGNullDirectDisplay)
                CGConfigureDisplayOrigin(config, physical.id, Int32(origin.x), Int32(origin.y))
                return true
            }
            physical.modeCache = nil
            if restoreMode, let previous = session.previousMode.flatMap({ physical.mode(matching: $0) }),
               physical.currentMode.map({ !$0.spec.matches(previous.spec) }) ?? true {
                physical.setMode(previous, option: .forAppOnly)
            }
        }
        // Keep the backend alive until the physical display has become active again.
        let backend = session.backend
        if releaseDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) { withExtendedLifetime(backend) {} }
        }
        Log.scaling.info("scaling session ended for \(session.key)")
    }

    private func backendTerminated(_ key: String) {
        guard sessions[key] != nil else { return }
        Log.scaling.error("backend for \(key) was terminated by the system")
        sessions[key] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reconcile() }
    }
}
