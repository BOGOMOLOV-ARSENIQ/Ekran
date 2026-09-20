import AppKit

/// Remembers the arrangement (positions, main display, resolutions) and restores it when macOS scrambles it,
/// e.g. after wake or when monitors are re-plugged in a different order.
final class LayoutProtection {
    static let shared = LayoutProtection()

    private let debouncer = Debouncer(delay: 1.5)
    private var recentEnforcements: [Date] = []

    var isEnabled: Bool { SettingsStore.shared.value.layoutProtectionEnabled }

    func setEnabled(_ enabled: Bool) {
        SettingsStore.shared.update { $0.layoutProtectionEnabled = enabled }
        if enabled { capture() }
    }

    /// Drawable displays keyed by the display the user thinks of (a scaling backend counts as its physical display).
    private func arrangedDisplays() -> [String: Display] {
        var result: [String: Display] = [:]
        for display in DisplayManager.shared.displays where display.isArranged {
            result[DisplayManager.shared.owner(of: display).key] = display
        }
        return result
    }

    func capture() {
        var entries: [String: LayoutSnapshot.Entry] = [:]
        for (key, display) in arrangedDisplays() {
            let origin = display.bounds.origin
            let mode = display.kind == .physical ? display.currentMode?.spec : nil
            entries[key] = LayoutSnapshot.Entry(x: origin.x, y: origin.y, mode: mode)
        }
        SettingsStore.shared.update { $0.protectedLayout = LayoutSnapshot(entries: entries) }
    }

    func scheduleCheck() {
        guard isEnabled, SettingsStore.shared.value.protectedLayout != nil else { return }
        debouncer.schedule { [weak self] in self?.enforce() }
    }

    private func enforce() {
        guard isEnabled, let snapshot = SettingsStore.shared.value.protectedLayout else { return }
        let current = arrangedDisplays()
        // Only restore when exactly the remembered set of displays is present.
        guard Set(current.keys) == Set(snapshot.entries.keys) else { return }

        var changes: [(Display, LayoutSnapshot.Entry, DisplayModeInfo?)] = []
        for (key, display) in current {
            guard let entry = snapshot.entries[key] else { continue }
            let origin = display.bounds.origin
            var mode: DisplayModeInfo?
            if let spec = entry.mode, display.kind == .physical, let currentMode = display.currentMode, !currentMode.spec.matches(spec) {
                mode = display.mode(matching: spec)
            }
            if origin.x != entry.x || origin.y != entry.y || mode != nil {
                changes.append((display, entry, mode))
            }
        }
        guard !changes.isEmpty else { return }

        // Guard against fighting another tool: at most three corrections per minute.
        recentEnforcements = recentEnforcements.filter { $0.timeIntervalSinceNow > -60 }
        guard recentEnforcements.count < 3 else { return }
        recentEnforcements.append(Date())

        configureDisplays(.permanently) { config in
            for (display, entry, mode) in changes {
                if let mode { CGConfigureDisplayWithDisplayMode(config, display.id, mode.mode, nil) }
                let origin = display.bounds.origin
                if origin.x != entry.x || origin.y != entry.y {
                    CGConfigureDisplayOrigin(config, display.id, Int32(entry.x), Int32(entry.y))
                }
            }
            return true
        }
        Log.display.info("layout restored for \(changes.count) display(s)")
    }
}
