import AppKit
import CPrivate

/// Unified brightness, contrast and volume control.
/// Apple panels use DisplayServices, external monitors DDC/CI, everything else software dimming.
final class BrightnessController {
    static let shared = BrightnessController()

    enum Source {
        case apple, ddc, software, none
    }

    enum Control {
        case brightness, contrast, volume
    }

    /// Posted (object: display ID) when a value read back from a monitor changed what Ekran shows.
    static let hardwareValuesChanged = Notification.Name("EkranHardwareValuesChanged")

    private static let softwareFloor = 0.06
    private static let combinedSplit = 0.3
    /// The monitor's own buttons change DDC values behind Ekran's back; older cached values are read again first.
    private static let hardwareValueLifetime: TimeInterval = 10

    private struct ReadKey: Hashable {
        let display: CGDirectDisplayID
        let code: VCP
    }

    private var ddcMaxima: [CGDirectDisplayID: [VCP: Int]] = [:]
    private var readAt: [ReadKey: Date] = [:]
    private var readsInFlight: Set<ReadKey> = []
    private var queuedSteps: [ReadKey: (control: Control, delta: Double)] = [:]
    private var observedSyncSource: CGDirectDisplayID?

    // MARK: Capabilities

    func brightnessSource(for display: Display) -> Source {
        guard display.kind == .physical else { return .none }
        switch display.settings.brightnessMethod {
        case .software:
            return .software
        case .hardware:
            return display.hasAppleBrightness ? .apple : display.ddc != nil ? .ddc : .none
        case .automatic:
            return display.hasAppleBrightness ? .apple : display.ddc != nil ? .ddc : .software
        }
    }

    func supports(_ control: Control, on display: Display) -> Bool {
        switch control {
        case .brightness: brightnessSource(for: display) != .none
        case .contrast, .volume: display.ddc != nil
        }
    }

    /// Reads the monitor's DDC values that are older than `maxAge` (all of them with 0).
    func refreshHardwareValues(for display: Display, maxAge: TimeInterval = 0) {
        guard display.ddc != nil else { return }
        for code in [VCP.brightness, .contrast, .volume] {
            if let date = readAt[ReadKey(display: display.id, code: code)], -date.timeIntervalSinceNow < maxAge { continue }
            beginRead(code, for: display)
        }
    }

    private func beginRead(_ code: VCP, for display: Display) {
        let readKey = ReadKey(display: display.id, code: code)
        guard let ddc = display.ddc, readsInFlight.insert(readKey).inserted else { return }
        ddc.read(code) { [weak self] reply in
            guard let self else { return }
            self.readsInFlight.remove(readKey)
            // Failures count as fresh too: a monitor showing its own menu does not answer, no need to insist.
            self.readAt[readKey] = Date()
            if let reply {
                self.ddcMaxima[display.id, default: [:]][code] = reply.maximum
                let value = Double(reply.current) / Double(reply.maximum)
                display.updateSettings { settings in
                    switch code {
                    case .brightness: settings.brightness = value
                    case .contrast: settings.contrast = value
                    case .volume: settings.volume = value
                    default: break
                    }
                }
                NotificationCenter.default.post(name: Self.hardwareValuesChanged, object: NSNumber(value: display.id))
            }
            if let pending = self.queuedSteps.removeValue(forKey: readKey) {
                self.applyStep(pending.control, pending.delta, on: display)
            }
        }
    }

    /// Values Ekran just wrote are authoritative until the monitor might have been changed again.
    private func markFresh(_ code: VCP, for display: Display) {
        readAt[ReadKey(display: display.id, code: code)] = Date()
    }

    private func ddcValue(_ fraction: Double, _ code: VCP, _ display: Display) -> UInt16 {
        let maximum = ddcMaxima[display.id]?[code] ?? 100
        return UInt16((fraction.clamped(to: 0 ... 1) * Double(maximum)).rounded())
    }

    // MARK: Brightness

    func brightness(of display: Display) -> Double {
        let settings = display.settings
        let dimming = settings.adjustments.dimming
        switch brightnessSource(for: display) {
        case .apple:
            var value: Float = 0
            let hardware = EKDSGetBrightness(display.id, &value) ? Double(value) : settings.brightness ?? 1
            return settings.combinedBrightness ? Self.combined(hardware: hardware, dimming: dimming) : hardware
        case .ddc:
            let hardware = settings.brightness ?? 1
            return settings.combinedBrightness ? Self.combined(hardware: hardware, dimming: dimming) : hardware
        case .software:
            return ((dimming - Self.softwareFloor) / (1 - Self.softwareFloor)).clamped(to: 0 ... 1)
        case .none:
            return 1
        }
    }

    func setBrightness(_ value: Double, for display: Display) {
        let value = value.clamped(to: 0 ... 1)
        let settings = display.settings
        switch brightnessSource(for: display) {
        case .apple, .ddc:
            if settings.combinedBrightness {
                let split = Self.split(value)
                setHardwareBrightness(split.hardware, for: display)
                setDimming(split.dimming, for: display)
            } else {
                setHardwareBrightness(value, for: display)
            }
        case .software:
            setDimming(Self.softwareFloor + (1 - Self.softwareFloor) * value, for: display)
        case .none:
            break
        }
    }

    private func setHardwareBrightness(_ value: Double, for display: Display) {
        if display.hasAppleBrightness {
            EKDSSetBrightness(display.id, Float(value))
        } else if let ddc = display.ddc {
            ddc.write(.brightness, ddcValue(value, .brightness, display))
            markFresh(.brightness, for: display)
        }
        if display.settings.brightness != value { display.updateSettings { $0.brightness = value } }
    }

    func setDimming(_ value: Double, for display: Display) {
        let value = value > 0.998 ? 1 : (value * 1000).rounded() / 1000
        guard display.settings.adjustments.dimming != value else { return }
        display.updateSettings { $0.adjustments.dimming = value }
        GammaController.shared.apply(display)
    }

    private static func split(_ value: Double) -> (hardware: Double, dimming: Double) {
        if value >= combinedSplit { return ((value - combinedSplit) / (1 - combinedSplit), 1) }
        return (0, softwareFloor + (1 - softwareFloor) * value / combinedSplit)
    }

    private static func combined(hardware: Double, dimming: Double) -> Double {
        if dimming < 0.999 { return combinedSplit * ((dimming - softwareFloor) / (1 - softwareFloor)).clamped(to: 0 ... 1) }
        return combinedSplit + hardware * (1 - combinedSplit)
    }

    // MARK: Contrast and volume (DDC)

    func contrast(of display: Display) -> Double { display.settings.contrast ?? 0.5 }

    func setContrast(_ value: Double, for display: Display) {
        guard let ddc = display.ddc else { return }
        let value = value.clamped(to: 0 ... 1)
        ddc.write(.contrast, ddcValue(value, .contrast, display))
        markFresh(.contrast, for: display)
        display.updateSettings { $0.contrast = value }
    }

    func volume(of display: Display) -> Double { display.settings.volume ?? 0.5 }

    func setVolume(_ value: Double, for display: Display) {
        guard let ddc = display.ddc else { return }
        let value = value.clamped(to: 0 ... 1)
        ddc.write(.volume, ddcValue(value, .volume, display))
        markFresh(.volume, for: display)
        if display.settings.muted, value > 0 { setMuted(false, for: display) }
        display.updateSettings { $0.volume = value }
    }

    func setMuted(_ muted: Bool, for display: Display) {
        guard let ddc = display.ddc else { return }
        ddc.write(.mute, muted ? 1 : 2)
        display.updateSettings { $0.muted = muted }
    }

    func setInput(_ input: UInt16, for display: Display) {
        display.ddc?.write(.inputSource, input)
    }

    // MARK: Keyboard steps

    func step(_ control: Control, by steps: Int, on displays: [Display], fine: Bool = false) {
        let delta = Double(steps) / (fine ? 64 : 16)
        for display in displays where supports(control, on: display) {
            guard let code = cachedDDCCode(control, on: display) else {
                applyStep(control, delta, on: display)
                continue
            }
            let readKey = ReadKey(display: display.id, code: code)
            if readsInFlight.contains(readKey) {
                // Key repeat while the current value is being read: apply everything once it arrives.
                queuedSteps[readKey] = (control, (queuedSteps[readKey]?.delta ?? 0) + delta)
            } else if let date = readAt[readKey], -date.timeIntervalSinceNow < Self.hardwareValueLifetime {
                applyStep(control, delta, on: display)
            } else {
                queuedSteps[readKey] = (control, delta)
                beginRead(code, for: display)
            }
        }
    }

    /// The DDC value a step starts from, when the control is backed by one.
    private func cachedDDCCode(_ control: Control, on display: Display) -> VCP? {
        guard display.ddc != nil else { return nil }
        switch control {
        case .brightness: return brightnessSource(for: display) == .ddc ? .brightness : nil
        case .contrast: return .contrast
        case .volume: return .volume
        }
    }

    private func applyStep(_ control: Control, _ delta: Double, on display: Display) {
        let value: Double
        switch control {
        case .brightness:
            value = (brightness(of: display) + delta).clamped(to: 0 ... 1)
            setBrightness(value, for: display)
        case .contrast:
            value = (contrast(of: display) + delta).clamped(to: 0 ... 1)
            setContrast(value, for: display)
        case .volume:
            value = (volume(of: display) + delta).clamped(to: 0 ... 1)
            setVolume(value, for: display)
        }
        let kind: OSD.Kind = switch control {
        case .brightness: .brightness
        case .volume: .volume
        case .contrast: .contrast
        }
        OSD.shared.show(kind, value: value, on: display)
    }

    func toggleMute(on displays: [Display]) {
        for display in displays where display.ddc != nil {
            let muted = !display.settings.muted
            setMuted(muted, for: display)
            OSD.shared.show(muted ? .mute : .volume, value: muted ? 0 : volume(of: display), on: display)
        }
    }

    // MARK: Sync (event driven via DisplayServices notifications)

    func updateSync() {
        let source = SettingsStore.shared.value.brightnessSyncEnabled
            ? DisplayManager.shared.physical.first { $0.isBuiltin && $0.hasAppleBrightness } ?? DisplayManager.shared.physical.first { $0.hasAppleBrightness }
            : nil
        guard source?.id != observedSyncSource else { return }
        if let observed = observedSyncSource { EKDSRemoveBrightnessObserver(observed) }
        observedSyncSource = nil
        if let source, EKDSAddBrightnessObserver(source.id, brightnessDidChange) {
            observedSyncSource = source.id
        }
    }

    fileprivate func syncSourceChanged(_ id: CGDirectDisplayID, value: Double) {
        guard id == observedSyncSource, SettingsStore.shared.value.brightnessSyncEnabled else { return }
        for display in DisplayManager.shared.physical where display.id != id && brightnessSource(for: display) != .none {
            setBrightness(value, for: display)
        }
    }
}

private func brightnessDidChange(_ display: CGDirectDisplayID, _ value: Double) {
    DispatchQueue.main.async { BrightnessController.shared.syncSourceChanged(display, value: value) }
}
