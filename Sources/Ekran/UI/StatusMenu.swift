import AppKit
import ScreenCaptureKit

/// Menu bar UI. The menu is rebuilt only when it opens (or while it is open and displays change),
/// so the app does no UI work in the background.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var isOpen = false
    private let windowList = WindowListMenu()
    /// Sliders currently in the menu that show hardware values, so readings from the monitor can update them.
    private var liveSliders: [(display: CGDirectDisplayID, control: BrightnessController.Control, view: MenuSliderView)] = []
    private var hardwareObserver: NSObjectProtocol?

    override init() {
        super.init()
        hardwareObserver = NotificationCenter.default.addObserver(
            forName: BrightnessController.hardwareValuesChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isOpen, let id = (note.object as? NSNumber)?.uint32Value,
                  let display = DisplayManager.shared.display(id: id) else { return }
            let brightness = BrightnessController.shared
            for slider in self.liveSliders where slider.display == id {
                switch slider.control {
                case .brightness: slider.view.show(brightness.brightness(of: display))
                case .volume: slider.view.show(brightness.volume(of: display))
                case .contrast: slider.view.show(brightness.contrast(of: display))
                }
            }
        }
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: "Ekran")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Ekran"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = true
        MediaKeyTap.shared.recheck()
        // The monitor's own buttons may have changed brightness or volume since Ekran last looked.
        for display in DisplayManager.shared.physical where display.ddc != nil {
            BrightnessController.shared.refreshHardwareValues(for: display, maxAge: 5)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { isOpen = false }
    }

    func refreshIfOpen() {
        if isOpen { rebuild() }
    }

    // MARK: Building

    private func rebuild() {
        menu.removeAllItems()
        liveSliders.removeAll()
        let conflicts = AppController.conflictingApps
        if !conflicts.isEmpty {
            menu.addNote("⚠︎ Запущен \(conflicts.joined(separator: ", ")) — возможны конфликты")
            menu.addItem(.separator())
        }
        if SettingsStore.shared.value.mediaKeysEnabled, MediaKeyTap.shared.status == .needsPermission {
            menu.add("Клавиши яркости: нужно разрешение…", symbol: "exclamationmark.triangle") {
                MediaKeyTap.shared.requestPermission()
            }
            menu.addItem(.separator())
        }
        let displays = DisplayManager.shared.visible
        for (index, display) in displays.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            addSection(for: display)
        }

        let disconnected = DisplayPowerController.shared.disconnected.values.sorted { $0.name < $1.name }
        if !disconnected.isEmpty {
            menu.addItem(.separator())
            menu.addHeader("Отключённые дисплеи")
            for item in disconnected {
                menu.add("Подключить «\(item.name)»", symbol: "powerplug") {
                    DisplayPowerController.shared.reconnect(item.id)
                }
            }
        }

        menu.addItem(.separator())
        addGlobalItems()
    }

    private func addSection(for display: Display) {
        let isMain = DisplayManager.shared.main === display
        menu.addHeader(display.name + (isMain && DisplayManager.shared.visible.count > 1 ? " · основной" : ""))
        switch display.kind {
        case .physical:
            addControls(for: display)
            addScalingSubmenu(for: display)
            if !display.settings.scalingEnabled { addResolutionSubmenu(for: display) }
            addOptionsSubmenu(for: display)
        case .virtualScreen, .otherVirtual:
            addResolutionSubmenu(for: display)
            menu.add("Картинка в картинке", symbol: "pip") {
                StreamController.shared.streamDisplay(display.id, title: display.name)
            }
            if let config = VirtualScreenController.shared.config(forDisplay: display.id) {
                menu.add("Выключить виртуальный экран", symbol: "power") {
                    VirtualScreenController.shared.stop(config.id)
                }
            }
        case .scalingBackend:
            break
        }
    }

    private func addControls(for display: Display) {
        let brightness = BrightnessController.shared
        let source = brightness.brightnessSource(for: display)
        if source != .none {
            let slider = MenuSliderView(
                symbol: source == .software ? "sun.min.fill" : "sun.max.fill",
                value: brightness.brightness(of: display), range: 0 ... 1, showsValue: false, format: percent,
                onChange: { brightness.setBrightness($0, for: display) })
            liveSliders.append((display.id, .brightness, slider))
            menu.addItem(slider.menuItem())
        }
        if XDRController.shared.isSupported(display), display.settings.xdrEnabled {
            let maximum = min(Double(display.edrPotential), XDRController.maxBoost)
            menu.addItem(MenuSliderView(
                symbol: "sun.max.trianglebadge.exclamationmark.fill",
                value: display.settings.xdrBoost.clamped(to: 1 ... maximum), range: 1 ... maximum,
                format: { "XDR \(Int(($0 * 100).rounded()))%" },
                onChange: { XDRController.shared.setBoost($0, for: display) }).menuItem())
        }
        if brightness.supports(.volume, on: display) {
            let slider = MenuSliderView(
                symbol: display.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                value: brightness.volume(of: display), range: 0 ... 1, showsValue: false, format: percent,
                onChange: { brightness.setVolume($0, for: display) })
            liveSliders.append((display.id, .volume, slider))
            menu.addItem(slider.menuItem())
        }
    }

    // MARK: Scaling

    private func addScalingSubmenu(for display: Display) {
        let scaling = ScalingController.shared
        let settings = display.settings
        let current = settings.scalingEnabled ? scaling.currentOption(for: display) : nil
        let title = current.map { "Масштаб: как \($0.title)" } ?? "Масштаб (HiDPI)"

        menu.addLazySubmenu(title, symbol: "arrow.up.left.and.arrow.down.right") { submenu in
            guard scaling.isSupported else {
                submenu.addNote("Виртуальные дисплеи недоступны в этой версии macOS")
                return
            }
            submenu.add("Гибкое масштабирование", checked: settings.scalingEnabled) {
                scaling.setEnabled(!settings.scalingEnabled, for: display)
            }

            let options = scaling.options(for: display)
            guard !options.isEmpty else { return }
            let selected = current ?? settings.scalingWidth.flatMap { w in options.first { $0.width == w } }
            let index = selected.flatMap { options.firstIndex(of: $0) } ?? options.count / 2

            submenu.addItem(.separator())
            submenu.addItem(MenuSliderView(
                symbol: "textformat.size", value: Double(options.count - 1 - index), range: 0 ... Double(options.count - 1),
                tickCount: options.count, width: 320,
                format: { options[options.count - 1 - Int($0.rounded())].title },
                onChange: { _ in },
                onCommit: { value in scaling.select(options[options.count - 1 - Int(value.rounded())], for: display) }).menuItem())
            submenu.addNote("Вправо — крупнее интерфейс")
            submenu.addItem(.separator())

            let native = display.nativePixelSize
            for option in options.reversed() {
                var title = "Как \(option.title)"
                if option.width * 2 == native.width { title += " — максимальная чёткость (2×)" }
                if option.width == native.width { title += " — 1:1 с суперсэмплингом" }
                if scaling.nativeMode(for: display, option: option) != nil { title += " · нативно" }
                submenu.add(title, checked: settings.scalingEnabled && option == selected) {
                    scaling.select(option, for: display)
                }
            }
            submenu.addItem(.separator())
            submenu.add("Свой размер…") {
                let initial = String(selected?.width ?? native.width / 2)
                if let size = Dialogs.size(title: "Свой размер", message: "Ширина рабочего стола в точках (высота подбирается по пропорциям экрана \(native.width)×\(native.height)).",
                                           initial: initial, widthOnly: true) {
                    scaling.addCustomWidth(size.width, for: display)
                }
            }
            submenu.add("Рендеринг в 2× (HiDPI)", checked: settings.scalingHiDPI) {
                scaling.setHiDPI(!settings.scalingHiDPI, for: display)
            }
            submenu.addItem(.separator())
            submenu.addNote("«Нативно» — режим macOS без виртуального дисплея (плавнее)")
            submenu.addNote("Остальные размеры — через скрытый виртуальный дисплей")
            if display.isBuiltin {
                submenu.addNote("Для встроенного экрана с вырезом лучше «Разрешение»")
            }
        }
    }

    // MARK: Resolution

    private func addResolutionSubmenu(for display: Display) {
        let current = display.currentMode
        let title = current.map { "Разрешение: \($0.spec.sizeTitle)\($0.isHiDPI ? " HiDPI" : "")" } ?? "Разрешение"
        menu.addLazySubmenu(title, symbol: "rectangle.dashed") { submenu in
            let showLow = SettingsStore.shared.value.showLowResolutionModes
            // Without the duplicates option CoreGraphics omits HiDPI modes entirely, so always take the full list.
            let all = display.modes()
            let hasHiDPI = all.contains(where: \.isHiDPI)
            // On Retina-class displays the 1× modes are "low resolution"; keep only the native one unless asked.
            let modes = !hasHiDPI || showLow ? all : all.filter { $0.isHiDPI || $0.isNative }
            let groups = Dictionary(grouping: modes) { mode in
                "\(mode.width)x\(mode.height)x\(mode.spec.pixelWidth)x\(mode.spec.pixelHeight)"
            }
            let currentRate = current?.refreshRate ?? -1
            let representatives = groups.values.compactMap { group -> DisplayModeInfo? in
                group.first { abs($0.refreshRate - currentRate) < 0.5 } ?? group.max { $0.refreshRate < $1.refreshRate }
            }
            let bySize: (DisplayModeInfo, DisplayModeInfo) -> Bool = { ($0.width, $0.height) > ($1.width, $1.height) }
            let hiDPI = representatives.filter(\.isHiDPI).sorted(by: bySize)
            let standard = representatives.filter { !$0.isHiDPI }.sorted(by: bySize)

            func addModes(_ list: [DisplayModeInfo], header: String) {
                guard !list.isEmpty else { return }
                submenu.addHeader(header)
                for mode in list {
                    var title = mode.spec.sizeTitle
                    if mode.isNative && !mode.isHiDPI { title += " — родное" }
                    if mode.isDefault { title += " — по умолчанию" }
                    let isCurrent = current.map { mode.hasSameSize(as: $0.spec) } ?? false
                    submenu.add(title, checked: isCurrent) { display.setMode(mode) }
                }
            }
            addModes(hiDPI, header: "HiDPI")
            addModes(standard, header: "Обычные")

            if let current {
                let rates = modes.filter { $0.hasSameSize(as: current.spec) }.sorted { $0.refreshRate > $1.refreshRate }
                if rates.count > 1 {
                    submenu.addItem(.separator())
                    submenu.addSubmenu("Частота: \(current.spec.refreshTitle)", symbol: "speedometer") { ratesMenu in
                        for mode in rates {
                            ratesMenu.add(mode.spec.refreshTitle, checked: abs(mode.refreshRate - current.refreshRate) < 0.01) {
                                display.setMode(mode)
                            }
                        }
                    }
                }
            }

            submenu.addItem(.separator())
            let favorites = display.settings.favoriteModes
            submenu.addSubmenu("Избранное", symbol: "star") { favoritesMenu in
                for spec in favorites {
                    let title = "\(spec.sizeTitle)\(spec.isHiDPI ? " HiDPI" : "") · \(spec.refreshTitle)"
                    favoritesMenu.add(title, checked: current?.spec.matches(spec) ?? false) {
                        if let mode = display.mode(matching: spec) { display.setMode(mode) }
                    }
                }
                if !favorites.isEmpty { favoritesMenu.addItem(.separator()) }
                if let current, !favorites.contains(where: { $0.matches(current.spec) }) {
                    favoritesMenu.add("Добавить текущее") {
                        display.updateSettings { $0.favoriteModes.append(current.spec) }
                    }
                }
                if let current, favorites.contains(where: { $0.matches(current.spec) }) {
                    favoritesMenu.add("Убрать текущее") {
                        display.updateSettings { $0.favoriteModes.removeAll { $0.matches(current.spec) } }
                    }
                }
            }
            if hasHiDPI {
                submenu.add("Показывать режимы низкого разрешения", checked: showLow) {
                    SettingsStore.shared.update { $0.showLowResolutionModes.toggle() }
                }
            }
        }
    }

    // MARK: Display options

    private func addOptionsSubmenu(for display: Display) {
        let brightness = BrightnessController.shared
        menu.addLazySubmenu("Параметры", symbol: "slider.horizontal.3") { submenu in
            let settings = display.settings
            submenu.addLazySubmenu("Изображение", symbol: "camera.filters") { image in
                self.addImageAdjustments(for: display, to: image)
            }
            if brightness.supports(.contrast, on: display) {
                submenu.addHeader("Контраст монитора")
                submenu.addItem(MenuSliderView(symbol: "circle.lefthalf.filled", value: brightness.contrast(of: display), range: 0 ... 1,
                                               showsValue: false, format: percent,
                                               onChange: { brightness.setContrast($0, for: display) }).menuItem())
            }

            if XDRController.shared.isSupported(display) || display.supportsHDRToggle {
                submenu.addItem(.separator())
            }
            if XDRController.shared.isSupported(display) {
                submenu.add("XDR-яркость (выше 100%)", symbol: "sun.max.trianglebadge.exclamationmark", checked: settings.xdrEnabled) {
                    XDRController.shared.setEnabled(!settings.xdrEnabled, for: display)
                }
            }
            if display.supportsHDRToggle {
                let enabled = DisplayPowerController.shared.isHDREnabled(display)
                submenu.add("HDR", symbol: "sparkles.tv", checked: enabled) {
                    DisplayPowerController.shared.setHDR(!enabled, for: display)
                }
            }

            submenu.addItem(.separator())
            submenu.addLazySubmenu("Цветовой профиль", symbol: "paintpalette") { profiles in
                self.addProfiles(for: display, to: profiles)
            }
            if display.ddc != nil {
                submenu.addSubmenu("Вход монитора", symbol: "cable.connector") { inputs in
                    for input in DDCInput.allCases {
                        inputs.add(input.title) { brightness.setInput(input.rawValue, for: display) }
                    }
                    inputs.addItem(.separator())
                    inputs.add("Свой код VCP 0x60…") {
                        if let text = Dialogs.text(title: "Код входа", message: "Десятичный или шестнадцатеричный (0x..) код DDC входа.", placeholder: "0x11"),
                           let code = text.lowercased().hasPrefix("0x") ? UInt16(text.dropFirst(2), radix: 16) : UInt16(text) {
                            brightness.setInput(code, for: display)
                        }
                    }
                }
                submenu.add("Перевести монитор в режим ожидания", symbol: "moon.zzz") {
                    display.ddc?.write(.powerMode, 4)
                }
            }

            submenu.addItem(.separator())
            submenu.addSubmenu("Регулировка яркости", symbol: "sun.max") { method in
                let titles: [BrightnessMethod: String] = [.automatic: "Автоматически", .hardware: "Только аппаратно (DDC / Apple)", .software: "Только программно"]
                for option in BrightnessMethod.allCases {
                    method.add(titles[option]!, checked: settings.brightnessMethod == option) {
                        display.updateSettings { $0.brightnessMethod = option }
                    }
                }
                method.addItem(.separator())
                method.add("Комбинированная (затемнение ниже минимума)", checked: settings.combinedBrightness) {
                    display.updateSettings { $0.combinedBrightness.toggle() }
                    // Turning it off must not leave the screen software-dimmed.
                    if settings.combinedBrightness { brightness.setDimming(1, for: display) }
                }
                if !display.isBuiltin && !display.hasAppleBrightness {
                    method.add("DDC/CI", checked: !settings.ddcDisabled) {
                        display.updateSettings { $0.ddcDisabled.toggle() }
                        AppController.shared.rediscoverDDC()
                    }
                }
            }

            if RefreshKeeper.shared.isSupported {
                submenu.addItem(.separator())
                submenu.add("Держать полную частоту", symbol: "speedometer", checked: settings.keepFullRefreshRate) {
                    RefreshKeeper.shared.setEnabled(!settings.keepFullRefreshRate, for: display)
                }
                submenu.addNote("Если видео идёт рывками, пока не двигаешь мышь")
            }

            submenu.addItem(.separator())
            submenu.add("Картинка в картинке", symbol: "pip") {
                let id = ScalingController.shared.backendID(for: display) ?? display.id
                StreamController.shared.streamDisplay(id, title: display.name)
            }
            if DisplayManager.shared.main !== display, DisplayManager.shared.visible.count > 1 {
                submenu.add("Сделать основным", symbol: "menubar.rectangle") { AppController.shared.makeMain(display) }
            }
            submenu.add("Информация о дисплее…", symbol: "info.circle") { InfoWindowController.show(for: display) }

            if DisplayPowerController.shared.isSupported {
                submenu.addItem(.separator())
                submenu.add("Отключить дисплей", symbol: "powerplug", enabled: DisplayPowerController.shared.canDisconnect(display)) {
                    DisplayPowerController.shared.disconnect(display)
                }
                submenu.add("Держать отключённым", checked: settings.keepDisconnected, enabled: DisplayPowerController.shared.canDisconnect(display) || settings.keepDisconnected) {
                    DisplayPowerController.shared.setKeepDisconnected(!settings.keepDisconnected, for: display)
                }
            }
        }
    }

    private func addImageAdjustments(for display: Display, to menu: NSMenu) {
        let adjustments = display.settings.adjustments
        func update(_ change: @escaping (inout ImageAdjustments, Double) -> Void) -> (Double) -> Void {
            { value in
                display.updateSettings { change(&$0.adjustments, value) }
                GammaController.shared.apply(display)
            }
        }
        menu.addHeader("Затемнение")
        menu.addItem(MenuSliderView(symbol: "moon.fill", value: adjustments.dimming, range: 0.05 ... 1, showsValue: false,
                                    format: percent, onChange: update { $0.dimming = $1 }).menuItem())
        menu.addHeader("Контраст")
        menu.addItem(MenuSliderView(symbol: "circle.lefthalf.filled", value: adjustments.contrast, range: 0.5 ... 1.5, showsValue: false,
                                    format: percent, onChange: update { $0.contrast = $1 }).menuItem())
        menu.addHeader("Гамма")
        menu.addItem(MenuSliderView(symbol: "chart.line.uptrend.xyaxis", value: adjustments.gamma, range: 0.5 ... 2, format: { String(format: "%.2f", $0) },
                                    onChange: update { $0.gamma = $1 }).menuItem())
        menu.addHeader("Цветовая температура")
        menu.addItem(MenuSliderView(symbol: "thermometer.medium", value: adjustments.temperature, range: -1 ... 1,
                                    format: { $0 < -0.02 ? "тёплее \(Int(-$0 * 100))" : $0 > 0.02 ? "холоднее \(Int($0 * 100))" : "нейтрально" },
                                    onChange: update { $0.temperature = $1 }).menuItem())
        menu.addHeader("Каналы RGB")
        menu.addItem(MenuSliderView(symbol: "r.circle", value: adjustments.red, range: 0 ... 1, showsValue: false, format: percent,
                                    onChange: update { $0.red = $1 }).menuItem())
        menu.addItem(MenuSliderView(symbol: "g.circle", value: adjustments.green, range: 0 ... 1, showsValue: false, format: percent,
                                    onChange: update { $0.green = $1 }).menuItem())
        menu.addItem(MenuSliderView(symbol: "b.circle", value: adjustments.blue, range: 0 ... 1, showsValue: false, format: percent,
                                    onChange: update { $0.blue = $1 }).menuItem())
        menu.addItem(.separator())
        menu.add("Инверсия цветов", checked: adjustments.invert) {
            display.updateSettings { $0.adjustments.invert.toggle() }
            GammaController.shared.apply(display)
        }
        menu.add("Сбросить", symbol: "arrow.counterclockwise", enabled: !adjustments.isIdentity) {
            display.updateSettings { $0.adjustments = ImageAdjustments() }
            GammaController.shared.apply(display)
        }
    }

    private func addProfiles(for display: Display, to menu: NSMenu) {
        let current = ColorProfiles.currentProfileURL(for: display)
        let factory = ColorProfiles.factoryProfileURL(for: display)
        menu.add("Заводской профиль", checked: current == nil || current == factory) {
            ColorProfiles.setProfile(nil, for: display)
        }
        menu.addItem(.separator())
        for profile in ColorProfiles.installed() {
            menu.add(profile.name, checked: current?.standardizedFileURL == profile.url.standardizedFileURL && current != factory) {
                ColorProfiles.setProfile(profile.url, for: display)
            }
        }
    }

    // MARK: Global

    private func addGlobalItems() {
        let virtual = VirtualScreenController.shared
        if virtual.isSupported {
            menu.addSubmenu("Виртуальные экраны", symbol: "display.2") { submenu in
                for config in virtual.configs {
                    let running = virtual.isRunning(config.id)
                    submenu.addSubmenu("\(config.name) · \(config.width)×\(config.height)\(config.hiDPI ? " HiDPI" : "")", symbol: running ? "checkmark.circle.fill" : "circle") { item in
                        item.add(running ? "Выключить" : "Включить") {
                            if running { virtual.stop(config.id) } else { virtual.start(config) }
                        }
                        if running, let id = virtual.displayID(for: config.id) {
                            item.add("Картинка в картинке", symbol: "pip") { StreamController.shared.streamDisplay(id, title: config.name) }
                        }
                        item.add("Включать при запуске", checked: config.launchAutomatically) {
                            var updated = config
                            updated.launchAutomatically.toggle()
                            SettingsStore.shared.update { settings in
                                if let index = settings.virtualScreens.firstIndex(where: { $0.id == config.id }) { settings.virtualScreens[index] = updated }
                            }
                        }
                        item.addItem(.separator())
                        item.add("Удалить", symbol: "trash") { virtual.remove(config.id) }
                    }
                }
                if !virtual.configs.isEmpty { submenu.addItem(.separator()) }
                for (width, height) in [(1920, 1080), (2560, 1440), (1920, 1200), (3840, 2160)] {
                    submenu.add("Создать \(width)×\(height) HiDPI") {
                        virtual.add(VirtualScreenConfig(name: "Виртуальный \(width)×\(height)", width: width, height: height))
                    }
                }
                submenu.add("Создать свой…") {
                    if let size = Dialogs.size(title: "Новый виртуальный экран", message: "Размер рабочего стола в точках, например 2560×1440.", initial: "1920×1080"),
                       let height = size.height {
                        virtual.add(VirtualScreenConfig(name: "Виртуальный \(size.width)×\(height)", width: size.width, height: height))
                    }
                }
            }
        }

        menu.addSubmenu("Пресеты", symbol: "square.stack.3d.up") { submenu in
            let presets = SettingsStore.shared.value.presets
            for preset in presets {
                submenu.add(preset.name) { PresetController.apply(preset) }
            }
            if !presets.isEmpty { submenu.addItem(.separator()) }
            submenu.add("Сохранить текущие настройки…") {
                if let name = Dialogs.text(title: "Новый пресет", message: "Сохраняет разрешение, масштаб, яркость, профиль и HDR всех дисплеев.", placeholder: "Работа") {
                    PresetController.save(name: name)
                }
            }
            if !presets.isEmpty {
                submenu.addSubmenu("Удалить") { remove in
                    for preset in presets { remove.add(preset.name) { PresetController.delete(preset.id) } }
                }
            }
        }

        let windowsItem = NSMenuItem(title: "Трансляция окна", action: nil, keyEquivalent: "")
        windowsItem.image = NSImage.symbol("macwindow.on.rectangle")
        let windowsMenu = NSMenu(title: "Трансляция окна")
        windowsMenu.delegate = windowList
        windowsMenu.autoenablesItems = false
        windowsItem.submenu = windowsMenu
        menu.addItem(windowsItem)

        menu.addItem(.separator())
        menu.add("Расположение дисплеев…", symbol: "rectangle.3.group") { ArrangementWindowController.show() }
        let protection = LayoutProtection.shared
        menu.add("Защищать расположение", symbol: "lock.rectangle.stack", checked: protection.isEnabled) {
            protection.setEnabled(!protection.isEnabled)
        }
        if protection.isEnabled {
            menu.add("Запомнить текущее расположение") { protection.capture() }
        }
        menu.addItem(.separator())
        menu.add("Настройки…", key: ",") { SettingsWindowController.show() }
        menu.add("Выйти из Ekran", key: "q") { NSApp.terminate(nil) }
    }
}

/// Lazily lists shareable windows; the list is fetched asynchronously when the submenu opens.
private final class WindowListMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard StreamController.shared.hasPermission else {
            menu.add("Разрешить запись экрана…") { StreamController.shared.requestPermission() }
            return
        }
        menu.addNote("Загрузка…")
        StreamController.shared.availableWindows { windows in
            menu.removeAllItems()
            guard !windows.isEmpty else {
                menu.addNote("Нет окон")
                return
            }
            for window in windows.prefix(40) {
                let app = window.owningApplication?.applicationName ?? ""
                menu.add("\(app) — \(window.title ?? "")") { StreamController.shared.streamWindow(window) }
            }
        }
    }
}
