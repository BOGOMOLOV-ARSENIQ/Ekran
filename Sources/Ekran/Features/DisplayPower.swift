import AppKit
import CPrivate

/// Software disconnect/reconnect of displays and HDR switching.
/// Disconnects are app-scoped: if Ekran quits or crashes, every display comes back on its own.
final class DisplayPowerController {
    static let shared = DisplayPowerController()

    struct Disconnected {
        let id: CGDirectDisplayID
        let key: String
        let name: String
    }

    private(set) var disconnected: [CGDirectDisplayID: Disconnected] = [:]

    var isSupported: Bool { EKCanConfigureDisplayEnabled() }

    func canDisconnect(_ display: Display) -> Bool {
        guard isSupported, display.kind == .physical else { return false }
        // Never leave the user without a visible physical display.
        return DisplayManager.shared.physical.contains { $0.id != display.id && $0.isOnline }
    }

    @discardableResult
    func disconnect(_ display: Display) -> Bool {
        guard canDisconnect(display) else { return false }
        if display.settings.scalingEnabled, ScalingController.shared.isActive(display) {
            // Unmirror first, the disconnect follows once the backend is gone.
            display.updateSettings { $0.scalingEnabled = false }
            ScalingController.shared.reconcile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let fresh = DisplayManager.shared.display(key: display.key) else { return }
                self.disconnect(fresh)
            }
            return true
        }
        let snapshot = ModeSnapshot(excluding: [display.id])
        let ok = configureDisplays(.forAppOnly) { EKConfigureDisplayEnabled($0, display.id, false) == .success }
        if ok {
            snapshot.restoreAfterTopologyChange()
            disconnected[display.id] = Disconnected(id: display.id, key: display.key, name: display.name)
            Log.display.info("disconnected \(display.name)")
        }
        return ok
    }

    @discardableResult
    func reconnect(_ id: CGDirectDisplayID) -> Bool {
        let snapshot = ModeSnapshot(excluding: [id])
        let ok = configureDisplays(.forAppOnly) { EKConfigureDisplayEnabled($0, id, true) == .success }
        if ok {
            disconnected[id] = nil
            snapshot.restoreAfterTopologyChange()
        }
        return ok
    }

    func reconnectAll() {
        for id in disconnected.keys { reconnect(id) }
    }

    func setKeepDisconnected(_ keep: Bool, for display: Display) {
        display.updateSettings { $0.keepDisconnected = keep }
        if keep { disconnect(display) }
    }

    /// Re-applies "keep disconnected" to displays that just appeared (for example after wake).
    func enforce(added: [Display]) {
        for display in added where display.settings.keepDisconnected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let fresh = DisplayManager.shared.display(key: display.key) else { return }
                self?.disconnect(fresh)
            }
        }
    }

    // MARK: HDR

    func isHDREnabled(_ display: Display) -> Bool {
        EKHDREnabled(display.id)
    }

    @discardableResult
    func setHDR(_ enabled: Bool, for display: Display) -> Bool {
        guard display.supportsHDRToggle else { return false }
        let ok = EKSetHDREnabled(display.id, enabled)
        if ok { OSD.shared.show(.text(enabled ? "HDR включён" : "HDR выключен", symbol: "sparkles.tv"), on: display) }
        return ok
    }
}
