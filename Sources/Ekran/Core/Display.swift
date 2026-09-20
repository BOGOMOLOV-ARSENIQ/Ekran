import AppKit
import CPrivate

enum EkranVendor {
    static let scaling: UInt32 = 0xEC01
    static let virtualScreen: UInt32 = 0xEC02
}

final class Display {
    enum Kind {
        case physical
        case scalingBackend   // our hidden HiDPI mirror source
        case virtualScreen    // user-created virtual screen
        case otherVirtual     // Sidecar, AirPlay, other apps
    }

    let id: CGDirectDisplayID
    let key: String
    let kind: Kind
    let isBuiltin: Bool
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    private(set) var info: [String: Any]
    private(set) var name: String

    /// DDC/CI channel when the monitor accepted a probe.
    var ddc: DDCChannel?

    /// Mode lists only change on reconfiguration, when DisplayManager clears this cache.
    var modeCache: [DisplayModeInfo]?

    init(id: CGDirectDisplayID) {
        self.id = id
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
        isBuiltin = CGDisplayIsBuiltin(id) != 0
        info = (EKCopyDisplayInfo(id) as? [String: Any]) ?? [:]

        switch vendor {
        case EkranVendor.scaling: kind = .scalingBackend
        case EkranVendor.virtualScreen: kind = .virtualScreen
        default:
            let isVirtual = info["kCGDisplayIsVirtualDevice"] as? Bool ?? false
            // Developer aid: lets foreign virtual displays stand in for monitors when testing scaling.
            let testing = ProcessInfo.processInfo.environment["EKRAN_TREAT_VIRTUAL_AS_PHYSICAL"] != nil
            kind = isVirtual && !testing ? .otherVirtual : .physical
        }

        if serial != 0 {
            key = "\(vendor)-\(model)-\(serial)"
        } else if let uuid = info["kCGDisplayUUID"] as? String {
            // Without a serial number the unit number is not stable (it follows connection order); the UUID is.
            key = "\(vendor)-\(model)-\(uuid)"
        } else {
            key = "\(vendor)-\(model)-u\(CGDisplayUnitNumber(id))"
        }
        if kind == .physical, serial == 0 {
            SettingsStore.shared.adoptLegacySettings(into: key, vendor: vendor, model: model, unit: CGDisplayUnitNumber(id))
        }
        name = ""
        name = resolveName()
    }

    // MARK: Live state

    var isOnline: Bool { CGDisplayIsOnline(id) != 0 }
    var isActive: Bool { CGDisplayIsActive(id) != 0 }
    /// Part of the desktop arrangement: online and not mirroring another display. Unlike `isActive` this stays
    /// true while the display sleeps.
    var isArranged: Bool { isOnline && mirrorSource == kCGNullDirectDisplay }
    var isMain: Bool { CGDisplayIsMain(id) != 0 }
    var mirrorSource: CGDirectDisplayID { CGDisplayMirrorsDisplay(id) }
    var bounds: CGRect { CGDisplayBounds(id) }
    var screen: NSScreen? { NSScreen.screen(for: id) }
    var isVirtual: Bool { kind != .physical }

    var settings: DisplaySettings { SettingsStore.shared.display(key) }

    func updateSettings(_ change: (inout DisplaySettings) -> Void) {
        SettingsStore.shared.updateDisplay(key, change)
    }

    func refreshName() {
        info = (EKCopyDisplayInfo(id) as? [String: Any]) ?? info
        name = resolveName()
        if kind == .physical, settings.name != name { updateSettings { $0.name = name } }
    }

    private func resolveName() -> String {
        if let screen, !screen.localizedName.isEmpty { return screen.localizedName.trimmedDisplayName }
        if let names = info["DisplayProductName"] as? [String: String] {
            let preferred = Locale.preferredLanguages.lazy.map { $0.replacingOccurrences(of: "-", with: "_") }
            if let match = preferred.compactMap({ lang in names.first { $0.key.hasPrefix(lang) }?.value }).first {
                return match.trimmedDisplayName
            }
            if let english = names["en_US"] ?? names.values.first { return english.trimmedDisplayName }
        }
        if isBuiltin { return "Встроенный дисплей" }
        return SettingsStore.shared.display(key).name ?? "Дисплей \(id)"
    }

    // MARK: Capabilities

    private(set) lazy var hasAppleBrightness: Bool = kind == .physical && EKDSCanChangeBrightness(id)

    var supportsHDRToggle: Bool { kind == .physical && EKHDRSupported(id) }

    /// Maximum EDR headroom the panel can provide (1.0 for SDR displays).
    var edrPotential: CGFloat { screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1 }

    var physicalSizeMillimeters: CGSize {
        let size = CGDisplayScreenSize(id)
        return size.width > 10 && size.height > 10 ? size : .zero
    }

    var chromaticity: EKChromaticity {
        func point(_ x: String, _ y: String, _ fallback: CGPoint) -> CGPoint {
            guard let px = info[x] as? Double, let py = info[y] as? Double, px > 0, py > 0 else { return fallback }
            return CGPoint(x: px, y: py)
        }
        return EKChromaticity(
            red: point("DisplayRedPointX", "DisplayRedPointY", CGPoint(x: 0.64, y: 0.33)),
            green: point("DisplayGreenPointX", "DisplayGreenPointY", CGPoint(x: 0.30, y: 0.60)),
            blue: point("DisplayBluePointX", "DisplayBluePointY", CGPoint(x: 0.15, y: 0.06)),
            white: point("DisplayWhitePointX", "DisplayWhitePointY", CGPoint(x: 0.3127, y: 0.3290)))
    }

    var edid: Data? {
        for key in ["IODisplayEDIDOriginal", "IODisplayEDID"] {
            if let data = info[key] as? Data, data.count >= 128 { return data }
        }
        return ddc?.copyEDID()
    }
}
