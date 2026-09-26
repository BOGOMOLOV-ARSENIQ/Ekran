import AppKit
import Combine

// MARK: - Models

struct ModeSpec: Codable, Hashable {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double

    var isHiDPI: Bool { pixelWidth > width }
}

struct ImageAdjustments: Codable, Equatable {
    var dimming = 1.0       // software brightness multiplier, 0...1
    var contrast = 1.0      // 0.5...1.5
    var gamma = 1.0         // 0.5...2.0
    var temperature = 0.0   // -1 warm ... +1 cool
    var red = 1.0
    var green = 1.0
    var blue = 1.0
    var invert = false

    static let identity = ImageAdjustments()

    var isIdentity: Bool {
        func one(_ value: Double) -> Bool { abs(value - 1) < 0.002 }
        return one(dimming) && one(contrast) && one(gamma) && abs(temperature) < 0.01
            && one(red) && one(green) && one(blue) && !invert
    }
}

enum BrightnessMethod: String, Codable, CaseIterable {
    case automatic, hardware, software
}

enum KeyTarget: String, Codable, CaseIterable {
    case mouse, main, all
}

struct DisplaySettings: Codable, Equatable {
    var name: String?
    // Flexible HiDPI scaling
    var scalingEnabled = false
    var scalingWidth: Int?
    var scalingHiDPI = true
    var customScalingWidths: [Int] = []
    // Hardware controls (last known values, 0...1)
    var brightness: Double?
    var contrast: Double?
    var volume: Double?
    var muted = false
    var brightnessMethod = BrightnessMethod.automatic
    var combinedBrightness = false
    var ddcDisabled = false
    // Image
    var adjustments = ImageAdjustments()
    var xdrEnabled = false
    var xdrBoost = 1.5
    /// Redraw on every vsync so video stays smooth without moving the cursor (see RefreshKeeper).
    var keepFullRefreshRate = false
    // Misc
    var favoriteModes: [ModeSpec] = []
    var keepDisconnected = false
    var onConnectScript = ""
    var onDisconnectScript = ""
}

struct VirtualScreenConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = "Виртуальный экран"
    var width = 1920
    var height = 1080
    var hiDPI = true
    var refreshRate = 60.0
    var launchAutomatically = true
}

enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case brightnessUp, brightnessDown, volumeUp, volumeDown, muteToggle, contrastUp, contrastDown
    case scaleLarger, scaleSmaller, scalingToggle, xdrToggle, hdrToggle, dimToggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightnessUp: "Яркость +"
        case .brightnessDown: "Яркость −"
        case .volumeUp: "Громкость +"
        case .volumeDown: "Громкость −"
        case .muteToggle: "Выключить звук"
        case .contrastUp: "Контраст +"
        case .contrastDown: "Контраст −"
        case .scaleLarger: "Масштаб: крупнее"
        case .scaleSmaller: "Масштаб: мельче"
        case .scalingToggle: "Гибкое масштабирование вкл/выкл"
        case .xdrToggle: "XDR-яркость вкл/выкл"
        case .hdrToggle: "HDR вкл/выкл"
        case .dimToggle: "Затемнение вкл/выкл"
        }
    }
}

struct HotkeyBinding: Codable, Hashable {
    var action: HotkeyAction
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask
}

struct PresetEntry: Codable, Equatable {
    var mode: ModeSpec?
    var scalingEnabled: Bool?
    var scalingWidth: Int?
    var brightness: Double?
    var adjustments: ImageAdjustments?
    var colorProfile: String?
    var hdr: Bool?
    var xdrEnabled: Bool?
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var displays: [String: PresetEntry]
}

struct LayoutSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var x: Double
        var y: Double
        var mode: ModeSpec?
    }
    var entries: [String: Entry]
}

struct AppSettings: Codable {
    var displays: [String: DisplaySettings] = [:]
    var virtualScreens: [VirtualScreenConfig] = []
    var presets: [Preset] = []
    var hotkeys: [HotkeyBinding] = []
    var showOSD = true
    var mediaKeysEnabled = false
    var mediaKeysControlVolume = true
    var keyTarget = KeyTarget.mouse
    var brightnessSyncEnabled = false
    var layoutProtectionEnabled = false
    var protectedLayout: LayoutSnapshot?
    var httpEnabled = false
    var httpPort = 55777
    var httpToken = ""
    var showLowResolutionModes = false
    /// The helper that owns the key tap has asked macOS for the Accessibility permission at least once.
    var keyHelperPrompted = false
}

// MARK: - Tolerant decoding (unknown or missing keys fall back to defaults)

extension KeyedDecodingContainer {
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension ImageAdjustments {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageAdjustments()
        dimming = c.value(.dimming, d.dimming)
        contrast = c.value(.contrast, d.contrast)
        gamma = c.value(.gamma, d.gamma)
        temperature = c.value(.temperature, d.temperature)
        red = c.value(.red, d.red)
        green = c.value(.green, d.green)
        blue = c.value(.blue, d.blue)
        invert = c.value(.invert, d.invert)
    }
}

extension DisplaySettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings()
        name = c.value(.name, d.name)
        scalingEnabled = c.value(.scalingEnabled, d.scalingEnabled)
        scalingWidth = c.value(.scalingWidth, d.scalingWidth)
        scalingHiDPI = c.value(.scalingHiDPI, d.scalingHiDPI)
        customScalingWidths = c.value(.customScalingWidths, d.customScalingWidths)
        brightness = c.value(.brightness, d.brightness)
        contrast = c.value(.contrast, d.contrast)
        volume = c.value(.volume, d.volume)
        muted = c.value(.muted, d.muted)
        brightnessMethod = c.value(.brightnessMethod, d.brightnessMethod)
        combinedBrightness = c.value(.combinedBrightness, d.combinedBrightness)
        ddcDisabled = c.value(.ddcDisabled, d.ddcDisabled)
        adjustments = c.value(.adjustments, d.adjustments)
        xdrEnabled = c.value(.xdrEnabled, d.xdrEnabled)
        xdrBoost = c.value(.xdrBoost, d.xdrBoost)
        keepFullRefreshRate = c.value(.keepFullRefreshRate, d.keepFullRefreshRate)
        favoriteModes = c.value(.favoriteModes, d.favoriteModes)
        keepDisconnected = c.value(.keepDisconnected, d.keepDisconnected)
        onConnectScript = c.value(.onConnectScript, d.onConnectScript)
        onDisconnectScript = c.value(.onDisconnectScript, d.onDisconnectScript)
    }
}

extension VirtualScreenConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VirtualScreenConfig()
        id = c.value(.id, d.id)
        name = c.value(.name, d.name)
        width = c.value(.width, d.width)
        height = c.value(.height, d.height)
        hiDPI = c.value(.hiDPI, d.hiDPI)
        refreshRate = c.value(.refreshRate, d.refreshRate)
        launchAutomatically = c.value(.launchAutomatically, d.launchAutomatically)
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        displays = c.value(.displays, d.displays)
        virtualScreens = c.value(.virtualScreens, d.virtualScreens)
        presets = c.value(.presets, d.presets)
        hotkeys = c.value(.hotkeys, d.hotkeys)
        showOSD = c.value(.showOSD, d.showOSD)
        mediaKeysEnabled = c.value(.mediaKeysEnabled, d.mediaKeysEnabled)
        mediaKeysControlVolume = c.value(.mediaKeysControlVolume, d.mediaKeysControlVolume)
        keyTarget = c.value(.keyTarget, d.keyTarget)
        brightnessSyncEnabled = c.value(.brightnessSyncEnabled, d.brightnessSyncEnabled)
        layoutProtectionEnabled = c.value(.layoutProtectionEnabled, d.layoutProtectionEnabled)
        protectedLayout = c.value(.protectedLayout, d.protectedLayout)
        httpEnabled = c.value(.httpEnabled, d.httpEnabled)
        httpPort = c.value(.httpPort, d.httpPort)
        httpToken = c.value(.httpToken, d.httpToken)
        showLowResolutionModes = c.value(.showLowResolutionModes, d.showLowResolutionModes)
        keyHelperPrompted = c.value(.keyHelperPrompted, d.keyHelperPrompted)
    }
}

// MARK: - Store

/// Main-thread settings store. Writes are coalesced so dragging a slider does not hit the disk on every step.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var value: AppSettings
    private let defaultsKey = "settings.v1"
    private let saveDebouncer = Debouncer(delay: 0.5)

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            // Entries created for Ekran's own virtual displays by earlier builds.
            decoded.displays = decoded.displays.filter { key, _ in
                !key.hasPrefix("\(EkranVendor.scaling)-") && !key.hasPrefix("\(EkranVendor.virtualScreen)-")
            }
            value = decoded
        } else {
            value = AppSettings()
        }
    }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&value)
        saveDebouncer.schedule { [weak self] in self?.flush() }
    }

    func display(_ key: String) -> DisplaySettings {
        value.displays[key] ?? DisplaySettings()
    }

    func updateDisplay(_ key: String, _ change: (inout DisplaySettings) -> Void) {
        update { settings in
            var display = settings.displays[key] ?? DisplaySettings()
            change(&display)
            settings.displays[key] = display
        }
    }

    /// Monitors without a serial number used to be keyed by their unit number, which changes when displays are
    /// reconnected in a different order (or after a reboot). Their settings move to the stable key once.
    func adoptLegacySettings(into key: String, vendor: UInt32, model: UInt32, unit: UInt32) {
        guard value.displays[key] == nil else { return }
        let prefix = "\(vendor)-\(model)-u"
        let legacy = value.displays.filter { $0.key.hasPrefix(prefix) }
        guard !legacy.isEmpty else { return }

        // Start from the entry used most recently (the current unit number) or the one with scaling configured,
        // then fill in configuration it lacks from the others.
        let base = legacy["\(prefix)\(unit)"]
            ?? legacy.values.first(where: \.scalingEnabled)
            ?? legacy.values.first!
        var merged = base
        for other in legacy.values {
            if !merged.scalingEnabled, merged.scalingWidth == nil, other.scalingEnabled || other.scalingWidth != nil {
                merged.scalingEnabled = other.scalingEnabled
                merged.scalingWidth = other.scalingWidth
                merged.scalingHiDPI = other.scalingHiDPI
            }
            if merged.customScalingWidths.isEmpty { merged.customScalingWidths = other.customScalingWidths }
            if merged.favoriteModes.isEmpty { merged.favoriteModes = other.favoriteModes }
            if merged.onConnectScript.isEmpty { merged.onConnectScript = other.onConnectScript }
            if merged.onDisconnectScript.isEmpty { merged.onDisconnectScript = other.onDisconnectScript }
            merged.keepDisconnected = merged.keepDisconnected || other.keepDisconnected
        }
        let legacyKeys = Set(legacy.keys)
        update { settings in
            for old in legacyKeys { settings.displays[old] = nil }
            settings.displays[key] = merged
            for index in settings.presets.indices {
                var entries = settings.presets[index].displays
                if let entry = legacyKeys.compactMap({ entries[$0] }).first { entries[key] = entry }
                for old in legacyKeys { entries[old] = nil }
                settings.presets[index].displays = entries
            }
            if var layout = settings.protectedLayout {
                if let entry = legacyKeys.compactMap({ layout.entries[$0] }).first { layout.entries[key] = entry }
                for old in legacyKeys { layout.entries[old] = nil }
                settings.protectedLayout = layout
            }
        }
        flush()
        Log.display.info("display settings moved from \(legacyKeys.sorted()) to \(key)")
    }

    func flush() {
        saveDebouncer.cancel()
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
