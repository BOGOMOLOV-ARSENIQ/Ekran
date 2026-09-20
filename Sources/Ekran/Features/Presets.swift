import AppKit

/// Named snapshots of display settings that can be applied from the menu, a hotkey or automation.
enum PresetController {
    static func capture(name: String) -> Preset {
        var entries: [String: PresetEntry] = [:]
        for display in DisplayManager.shared.physical {
            let settings = display.settings
            var entry = PresetEntry()
            if !ScalingController.shared.isActive(display) { entry.mode = display.currentMode?.spec }
            entry.scalingEnabled = settings.scalingEnabled
            entry.scalingWidth = settings.scalingWidth
            if BrightnessController.shared.brightnessSource(for: display) != .none {
                entry.brightness = BrightnessController.shared.brightness(of: display)
            }
            entry.adjustments = settings.adjustments
            entry.colorProfile = ColorProfiles.currentProfileURL(for: display)?.path
            if display.supportsHDRToggle { entry.hdr = DisplayPowerController.shared.isHDREnabled(display) }
            if XDRController.shared.isSupported(display) { entry.xdrEnabled = settings.xdrEnabled }
            entries[display.key] = entry
        }
        return Preset(name: name, displays: entries)
    }

    static func save(name: String) {
        let preset = capture(name: name)
        SettingsStore.shared.update { settings in
            if let index = settings.presets.firstIndex(where: { $0.name == name }) {
                settings.presets[index] = Preset(id: settings.presets[index].id, name: name, displays: preset.displays)
            } else {
                settings.presets.append(preset)
            }
        }
    }

    static func apply(_ preset: Preset) {
        for display in DisplayManager.shared.physical {
            guard let entry = preset.displays[display.key] else { continue }
            if let adjustments = entry.adjustments {
                display.updateSettings { $0.adjustments = adjustments }
                GammaController.shared.apply(display)
            }
            if let brightness = entry.brightness {
                BrightnessController.shared.setBrightness(brightness, for: display)
            }
            if let path = entry.colorProfile, ColorProfiles.currentProfileURL(for: display)?.path != path {
                ColorProfiles.setProfile(URL(fileURLWithPath: path), for: display)
            }
            if let hdr = entry.hdr, display.supportsHDRToggle, DisplayPowerController.shared.isHDREnabled(display) != hdr {
                DisplayPowerController.shared.setHDR(hdr, for: display)
            }
            if let xdr = entry.xdrEnabled, XDRController.shared.isSupported(display) {
                display.updateSettings { $0.xdrEnabled = xdr }
            }
            if let enabled = entry.scalingEnabled {
                display.updateSettings {
                    $0.scalingEnabled = enabled
                    if let width = entry.scalingWidth { $0.scalingWidth = width }
                }
                if !enabled, let spec = entry.mode, let mode = display.mode(matching: spec), display.currentMode?.spec.matches(spec) != true {
                    display.setMode(mode)
                }
            }
        }
        ScalingController.shared.reconcile()
        XDRController.shared.sync()
    }

    static func apply(named name: String) -> Bool {
        guard let preset = SettingsStore.shared.value.presets.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        apply(preset)
        return true
    }

    static func delete(_ id: UUID) {
        SettingsStore.shared.update { $0.presets.removeAll { $0.id == id } }
    }
}
