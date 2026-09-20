import CoreGraphics
import Foundation

/// Composes the per-display gamma table: software dimming, image adjustments and XDR boost.
/// The table is applied by the display pipeline itself, so it costs nothing per frame.
/// macOS restores the original tables automatically when the app exits or crashes.
final class GammaController {
    static let shared = GammaController()

    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private var originals: [CGDirectDisplayID: Table] = [:]
    private var modified: Set<CGDirectDisplayID> = []
    private var lastWhite: [CGDirectDisplayID: CGGammaValue] = [:]

    /// Values above 1.0 only make sense while EDR is active on an XDR/HDR panel.
    func effectiveBoost(for display: Display) -> Double {
        let settings = display.settings
        guard settings.xdrEnabled, XDRController.shared.isActive(on: display) else { return 1 }
        return settings.xdrBoost.clamped(to: 1 ... min(XDRController.maxBoost, Double(max(display.edrPotential, 1))))
    }

    func apply(_ display: Display) {
        guard display.kind == .physical else { return }
        let adjustments = display.settings.adjustments
        let boost = effectiveBoost(for: display)

        if adjustments.isIdentity && boost == 1 {
            restore(display.id)
            return
        }
        guard let original = original(for: display.id) else { return }

        let count = original.red.count
        var red = [CGGammaValue](repeating: 0, count: count)
        var green = red
        var blue = red

        // Colour temperature as simple channel gains (warm lowers blue, cool lowers red).
        let t = adjustments.temperature.clamped(to: -1 ... 1)
        let temperatureGain = t < 0
            ? (r: 1.0, g: 1 + t * 0.22, b: 1 + t * 0.6)
            : (r: 1 - t * 0.35, g: 1 - t * 0.12, b: 1.0)
        let scale = adjustments.dimming.clamped(to: 0 ... 1) * boost
        let gains = (
            r: adjustments.red * temperatureGain.r * scale,
            g: adjustments.green * temperatureGain.g * scale,
            b: adjustments.blue * temperatureGain.b * scale)
        let contrast = adjustments.contrast
        let inverseGamma = 1 / adjustments.gamma.clamped(to: 0.3 ... 3)
        let last = count - 1

        func channel(_ source: [CGGammaValue], _ gain: Double, _ index: Int) -> CGGammaValue {
            var value = Double(source[adjustments.invert ? last - index : index])
            if contrast != 1 { value = ((value - 0.5) * contrast + 0.5).clamped(to: 0 ... 1) }
            if inverseGamma != 1 { value = pow(value, inverseGamma) }
            return CGGammaValue(value * gain)
        }
        for i in 0 ..< count {
            red[i] = channel(original.red, gains.r, i)
            green[i] = channel(original.green, gains.g, i)
            blue[i] = channel(original.blue, gains.b, i)
        }
        if CGSetDisplayTransferByTable(display.id, UInt32(count), red, green, blue) == .success {
            modified.insert(display.id)
            lastWhite[display.id] = red[last]
        }
    }

    /// Re-applies the table if something else (the system, another app) replaced it.
    func verify(_ display: Display) {
        guard modified.contains(display.id), let expected = lastWhite[display.id], let count = originals[display.id]?.red.count else { return }
        var red = [CGGammaValue](repeating: 0, count: count)
        var green = red
        var blue = red
        var sampled: UInt32 = 0
        guard CGGetDisplayTransferByTable(display.id, UInt32(count), &red, &green, &blue, &sampled) == .success, sampled > 0 else { return }
        if abs(red[Int(sampled) - 1] - expected) > 0.003 { apply(display) }
    }

    func applyAll() {
        DisplayManager.shared.physical.forEach(apply)
    }

    /// After reconfiguration or a colour profile change the system may have replaced the tables,
    /// so the originals are recaptured before our adjustments are applied again.
    func reloadAll() {
        guard !modified.isEmpty || DisplayManager.shared.physical.contains(where: needsTable) else { return }
        CGDisplayRestoreColorSyncSettings()
        modified.removeAll()
        originals.removeAll()
        lastWhite.removeAll()
        applyAll()
    }

    func resetAll() {
        if !modified.isEmpty { CGDisplayRestoreColorSyncSettings() }
        modified.removeAll()
        originals.removeAll()
    }

    private func needsTable(_ display: Display) -> Bool {
        !display.settings.adjustments.isIdentity || display.settings.xdrEnabled
    }

    private func restore(_ id: CGDirectDisplayID) {
        guard modified.contains(id), let original = originals[id] else { return }
        CGSetDisplayTransferByTable(id, UInt32(original.red.count), original.red, original.green, original.blue)
        modified.remove(id)
        lastWhite[id] = nil
    }

    private func original(for id: CGDirectDisplayID) -> Table? {
        if let table = originals[id] { return table }
        // Never capture a table we modified ourselves.
        guard !modified.contains(id) else { return nil }
        let capacity = Int(min(max(CGDisplayGammaTableCapacity(id), 256), 1024))
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = red
        var blue = red
        var sampled: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, UInt32(capacity), &red, &green, &blue, &sampled) == .success, sampled > 1 else {
            return nil
        }
        let n = Int(sampled)
        let table = Table(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
        originals[id] = table
        return table
    }
}
