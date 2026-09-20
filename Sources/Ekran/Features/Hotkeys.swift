import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon hot keys: no Accessibility permission and no event tap needed.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var handler: EventHandlerRef?

    /// Temporarily unregisters every shortcut (used while recording a new one).
    func suspend() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        actions.removeAll()
    }

    func reload() {
        suspend()
        let bindings = SettingsStore.shared.value.hotkeys
        guard !bindings.isEmpty else { return }
        installHandlerIfNeeded()

        for (index, binding) in bindings.enumerated() {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x454B_524E), id: UInt32(index + 1))  // 'EKRN'
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references.append(reference)
                actions[identifier.id] = binding.action
            } else {
                Log.general.error("hotkey registration failed for \(binding.action.rawValue): \(status)")
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            if status == noErr {
                let id = identifier.id
                DispatchQueue.main.async { HotkeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        ActionPerformer.perform(action)
    }
}

/// Shared implementation of keyboard driven actions (hotkeys and media keys).
enum ActionPerformer {
    static func perform(_ action: HotkeyAction, fine: Bool = false) {
        let targets = DisplayManager.shared.targets(for: SettingsStore.shared.value.keyTarget)
        let brightness = BrightnessController.shared
        switch action {
        case .brightnessUp: brightness.step(.brightness, by: 1, on: targets, fine: fine)
        case .brightnessDown: brightness.step(.brightness, by: -1, on: targets, fine: fine)
        case .volumeUp: brightness.step(.volume, by: 1, on: targets, fine: fine)
        case .volumeDown: brightness.step(.volume, by: -1, on: targets, fine: fine)
        case .muteToggle: brightness.toggleMute(on: targets)
        case .contrastUp: brightness.step(.contrast, by: 1, on: targets, fine: fine)
        case .contrastDown: brightness.step(.contrast, by: -1, on: targets, fine: fine)
        case .scaleLarger: targets.forEach { ScalingController.shared.step($0, by: 1) }
        case .scaleSmaller: targets.forEach { ScalingController.shared.step($0, by: -1) }
        case .scalingToggle:
            targets.forEach { ScalingController.shared.setEnabled(!$0.settings.scalingEnabled, for: $0) }
        case .xdrToggle:
            for display in targets where XDRController.shared.isSupported(display) {
                let enabled = !display.settings.xdrEnabled
                XDRController.shared.setEnabled(enabled, for: display)
                OSD.shared.show(.text(enabled ? "XDR-яркость включена" : "XDR-яркость выключена", symbol: "sun.max.fill"), on: display)
            }
        case .hdrToggle:
            for display in targets where display.supportsHDRToggle {
                DisplayPowerController.shared.setHDR(!DisplayPowerController.shared.isHDREnabled(display), for: display)
            }
        case .dimToggle:
            for display in targets {
                let dimmed = display.settings.adjustments.dimming < 1
                BrightnessController.shared.setDimming(dimmed ? 1 : 0.5, for: display)
                OSD.shared.show(.text(dimmed ? "Затемнение выключено" : "Затемнение 50%", symbol: "moon.fill"), on: display)
            }
        }
    }
}

enum KeyNames {
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    static func keyName(_ keyCode: UInt32) -> String {
        if let name = special[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
