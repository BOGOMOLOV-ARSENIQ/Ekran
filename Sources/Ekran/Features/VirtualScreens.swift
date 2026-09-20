import AppKit
import CPrivate

/// User-defined virtual screens (headless displays for screen sharing, recording, streaming into a window…).
final class VirtualScreenController {
    static let shared = VirtualScreenController()

    private var running: [UUID: EKVirtualDisplay] = [:]
    private var pendingModes: [UUID: Int] = [:]
    private let retry = Debouncer(delay: 0.3)

    var isSupported: Bool { EKVirtualDisplay.isSupported() }
    var configs: [VirtualScreenConfig] { SettingsStore.shared.value.virtualScreens }

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    func displayID(for id: UUID) -> CGDirectDisplayID? { running[id]?.displayID }

    func config(forDisplay displayID: CGDirectDisplayID) -> VirtualScreenConfig? {
        guard let id = running.first(where: { $0.value.displayID == displayID })?.key else { return nil }
        return configs.first { $0.id == id }
    }

    func startAutomatic() {
        configs.filter(\.launchAutomatically).forEach { start($0) }
    }

    @discardableResult
    func start(_ config: VirtualScreenConfig) -> Bool {
        guard isSupported, running[config.id] == nil else { return running[config.id] != nil }
        let factor = config.hiDPI ? 2 : 1
        var options = ScalingController.ladder(native: (config.width, config.height))
        if !options.contains(where: { $0.width == config.width && $0.height == config.height }) {
            options.append(ScaleOption(width: config.width, height: config.height))
        }
        options = options.filter { $0.width * factor <= 8192 && $0.height * factor <= 8192 }
        guard !options.isEmpty else { return false }

        // Physical size of a 24″ panel with the same aspect ratio keeps macOS' DPI heuristics sensible.
        let diagonal = (Double(config.width * config.width + config.height * config.height)).squareRoot()
        let millimetersPerPoint = 24 * 25.4 / diagonal
        let hash = stableHash(config.id.uuidString)
        let id = config.id
        let snapshot = ModeSnapshot()
        guard let display = EKVirtualDisplay(
            name: config.name,
            maxPixelsWide: UInt32(options.map(\.width).max()! * factor),
            maxPixelsHigh: UInt32(options.map(\.height).max()! * factor),
            sizeInMillimeters: CGSize(width: Double(config.width) * millimetersPerPoint, height: Double(config.height) * millimetersPerPoint),
            vendorID: EkranVendor.virtualScreen,
            productID: hash & 0xFFFF,
            serialNumber: hash,
            chromaticity: EKChromaticity(red: CGPoint(x: 0.64, y: 0.33), green: CGPoint(x: 0.30, y: 0.60),
                                         blue: CGPoint(x: 0.15, y: 0.06), white: CGPoint(x: 0.3127, y: 0.3290)),
            terminationHandler: { [weak self] in
                DispatchQueue.main.async { self?.running[id] = nil }
            })
        else { return false }

        // Logical sizes: with hiDPI each W×H is backed by a 2W×2H framebuffer (see ScalingController).
        let modes = options.map {
            EKVirtualMode(width: UInt32($0.width), height: UInt32($0.height), refreshRate: config.refreshRate)
        }
        guard modes.withUnsafeBufferPointer({ display.applyModes($0.baseAddress!, count: UInt($0.count), hiDPI: config.hiDPI) }) else {
            return false
        }
        running[config.id] = display
        pendingModes[config.id] = 0
        // Configuring a display while WindowServer is still adding it blocks for seconds; wait for the
        // reconfiguration to be processed (DisplayManager registers the display) before selecting the mode.
        retry.schedule { [weak self] in self?.applyPendingModes() }
        snapshot.restoreAfterTopologyChange()
        return true
    }

    func stop(_ id: UUID) {
        guard running[id] != nil else { return }
        let snapshot = ModeSnapshot()
        running[id] = nil
        pendingModes[id] = nil
        snapshot.restoreAfterTopologyChange()
    }

    func stopAll() {
        running.removeAll()
        pendingModes.removeAll()
    }

    func add(_ config: VirtualScreenConfig) {
        SettingsStore.shared.update { $0.virtualScreens.append(config) }
        start(config)
    }

    func remove(_ id: UUID) {
        stop(id)
        SettingsStore.shared.update { $0.virtualScreens.removeAll { $0.id == id } }
    }

    func update(_ config: VirtualScreenConfig) {
        SettingsStore.shared.update { settings in
            if let index = settings.virtualScreens.firstIndex(where: { $0.id == config.id }) {
                settings.virtualScreens[index] = config
            }
        }
        if isRunning(config.id) {
            stop(config.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start(config) }
        }
    }

    /// Selects the configured size once the new display has published its modes.
    /// Also called after every display change, which covers waking from display sleep.
    func applyPendingModes() {
        guard !pendingModes.isEmpty, !areDisplaysAsleep else { return }
        for (id, attempts) in pendingModes {
            guard let display = running[id], let config = configs.first(where: { $0.id == id }) else {
                pendingModes[id] = nil
                continue
            }
            guard DisplayManager.shared.display(id: display.displayID) != nil else {
                pendingModes[id] = attempts > 40 ? nil : attempts + 1
                continue
            }
            let factor = config.hiDPI ? 2 : 1
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode] ?? []
            if let mode = modes.first(where: {
                $0.isUsableForDesktopGUI() && $0.width == config.width && $0.height == config.height && $0.pixelWidth == config.width * factor
            }) {
                let current = CGDisplayCopyDisplayMode(display.displayID)
                if current?.width != mode.width || current?.pixelWidth != mode.pixelWidth || current?.height != mode.height {
                    configureDisplays(.forAppOnly) { CGConfigureDisplayWithDisplayMode($0, display.displayID, mode, nil) == .success }
                }
                pendingModes[id] = nil
            } else if attempts > 40 {
                pendingModes[id] = nil
            } else {
                pendingModes[id] = attempts + 1
            }
        }
        if !pendingModes.isEmpty {
            retry.schedule { [weak self] in self?.applyPendingModes() }
        }
    }
}
