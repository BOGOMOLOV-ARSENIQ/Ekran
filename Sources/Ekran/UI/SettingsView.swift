import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

enum SettingsWindowController {
    static func show() {
        WindowPresenter.shared.show(id: "settings", title: "Настройки Ekran", size: NSSize(width: 700, height: 600)) {
            SettingsView()
        }
    }
}

extension SettingsStore {
    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>, didSet: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(get: { self.value[keyPath: keyPath] }, set: { newValue in
            self.update { $0[keyPath: keyPath] = newValue }
            didSet?(newValue)
        })
    }

    func displayBinding<T>(_ key: String, _ keyPath: WritableKeyPath<DisplaySettings, T>, didSet: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(get: { self.display(key)[keyPath: keyPath] }, set: { newValue in
            self.updateDisplay(key) { $0[keyPath: keyPath] = newValue }
            didSet?(newValue)
        })
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Dialogs.info(title: "Не удалось изменить автозапуск",
                         message: "\(error.localizedDescription)\n\nПереместите Ekran в «Программы» и попробуйте снова.")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return isEnabled
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("Основные", systemImage: "gearshape") }
            DisplaySettingsView().tabItem { Label("Дисплеи", systemImage: "display") }
            HotkeySettingsView().tabItem { Label("Клавиши", systemImage: "keyboard") }
            VirtualScreenSettingsView().tabItem { Label("Виртуальные", systemImage: "display.2") }
            AutomationSettingsView().tabItem { Label("Автоматизация", systemImage: "terminal") }
            AboutView().tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(minWidth: 640, minHeight: 540)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var keys = MediaKeyTap.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = LaunchAtLogin.set($0) }))
                Toggle("Показывать индикатор изменений", isOn: store.binding(\.showOSD))
            }

            Section("Клавиатура") {
                Toggle("Клавиши яркости и громкости управляют внешними мониторами", isOn: Binding(
                    get: { store.value.mediaKeysEnabled },
                    set: { MediaKeyTap.shared.setEnabled($0) }))
                if store.value.mediaKeysEnabled {
                    KeyTapStatusRow(status: keys.status)
                }
                Toggle("Клавиши громкости меняют громкость монитора (звук через HDMI/DisplayPort)", isOn: store.binding(\.mediaKeysControlVolume))
                    .disabled(!store.value.mediaKeysEnabled)
                Picker("Клавиши действуют на", selection: store.binding(\.keyTarget)) {
                    Text("дисплей под курсором").tag(KeyTarget.mouse)
                    Text("основной дисплей").tag(KeyTarget.main)
                    Text("все дисплеи").tag(KeyTarget.all)
                }
                Text("⌥⇧ + клавиша яркости или громкости — мелкий шаг.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Яркость") {
                Toggle("Синхронизировать внешние мониторы с яркостью встроенного дисплея",
                       isOn: store.binding(\.brightnessSyncEnabled) { _ in BrightnessController.shared.updateSync() })
            }

            Section("Расположение") {
                Toggle("Защищать расположение и разрешения дисплеев",
                       isOn: Binding(get: { store.value.layoutProtectionEnabled }, set: { LayoutProtection.shared.setEnabled($0) }))
                HStack {
                    Button("Запомнить текущее расположение") { LayoutProtection.shared.capture() }
                    Button("Открыть редактор расположения…") { ArrangementWindowController.show() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            MediaKeyTap.shared.recheck()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

private struct KeyTapStatusRow: View {
    let status: MediaKeyTap.Status

    var body: some View {
        switch status {
        case .active:
            Label("Работает", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsPermission:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Нужно разрешение для «Ekran Keys»", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Разрешить…") { MediaKeyTap.shared.requestPermission() }
                }
                Text("В «Конфиденциальность и безопасность → Универсальный доступ» включите Ekran Keys. Это разрешение не сбрасывается при обновлении Ekran; старую запись «Ekran» можно удалить.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .starting:
            Label("Запуск…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .idle:
            Label("Включится, когда подключён монитор с регулировкой яркости или звука", systemImage: "moon.zzz").foregroundStyle(.secondary)
        case .unavailable:
            Label("Помощник Ekran Keys не запустился — пересоберите приложение (./build.sh)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .off:
            EmptyView()
        }
    }
}

// MARK: - Displays

private struct DisplaySettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var selection = ""

    private var entries: [(key: String, name: String, online: Bool)] {
        let online = DisplayManager.shared.physical
        var result = online.map { (key: $0.key, name: $0.name, online: true) }
        for (key, settings) in store.value.displays where !online.contains(where: { $0.key == key }) {
            result.append((key: key, name: settings.name ?? key, online: false))
        }
        return result
    }

    var body: some View {
        Form {
            Section {
                Picker("Дисплей", selection: $selection) {
                    ForEach(entries, id: \.key) { entry in
                        Text(entry.online ? entry.name : "\(entry.name) — не подключён").tag(entry.key)
                    }
                }
            }
            if !selection.isEmpty {
                DisplayDetail(key: selection)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if selection.isEmpty || !entries.contains(where: { $0.key == selection }) { selection = entries.first?.key ?? "" }
        }
    }
}

private struct DisplayDetail: View {
    let key: String
    @ObservedObject private var store = SettingsStore.shared

    private var display: Display? { DisplayManager.shared.display(key: key) }

    var body: some View {
        let settings = store.display(key)
        Section("Яркость") {
            Picker("Регулировка", selection: store.displayBinding(key, \.brightnessMethod)) {
                Text("Автоматически").tag(BrightnessMethod.automatic)
                Text("Только аппаратно (DDC / Apple)").tag(BrightnessMethod.hardware)
                Text("Только программно").tag(BrightnessMethod.software)
            }
            Toggle("Комбинированная: ниже аппаратного минимума — программное затемнение",
                   isOn: store.displayBinding(key, \.combinedBrightness) { enabled in
                       if !enabled, let display { BrightnessController.shared.setDimming(1, for: display) }
                   })
            Toggle("Использовать DDC/CI", isOn: Binding(
                get: { !settings.ddcDisabled },
                set: { enabled in
                    store.updateDisplay(key) { $0.ddcDisabled = !enabled }
                    AppController.shared.rediscoverDDC()
                }))
        }

        Section("Масштабирование") {
            Toggle("Гибкое HiDPI-масштабирование", isOn: Binding(
                get: { settings.scalingEnabled },
                set: { enabled in
                    if let display { ScalingController.shared.setEnabled(enabled, for: display) } else {
                        store.updateDisplay(key) { $0.scalingEnabled = enabled }
                    }
                }))
            Toggle("Рендеринг в 2× (HiDPI)", isOn: Binding(
                get: { settings.scalingHiDPI },
                set: { enabled in
                    if let display { ScalingController.shared.setHiDPI(enabled, for: display) } else {
                        store.updateDisplay(key) { $0.scalingHiDPI = enabled }
                    }
                }))
            TextField("Свои размеры (ширина через запятую)", text: Binding(
                get: { settings.customScalingWidths.map(String.init).joined(separator: ", ") },
                set: { text in
                    let widths = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (640 ... 8192).contains($0) }
                    store.updateDisplay(key) { $0.customScalingWidths = Array(Set(widths)).sorted() }
                }))
            Text("Новые размеры появятся в меню после повторного включения масштабирования.").font(.caption).foregroundStyle(.secondary)
        }

        Section("Сценарии") {
            TextField("При подключении (zsh)", text: store.displayBinding(key, \.onConnectScript), axis: .vertical)
                .font(.system(.body, design: .monospaced))
            TextField("При отключении (zsh)", text: store.displayBinding(key, \.onDisconnectScript), axis: .vertical)
                .font(.system(.body, design: .monospaced))
            Text("Доступны переменные $EKRAN_DISPLAY_NAME, $EKRAN_DISPLAY_ID, $EKRAN_DISPLAY_KEY и $EKRAN_EVENT.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            Toggle("Держать отключённым (пока Ekran запущен)", isOn: Binding(
                get: { settings.keepDisconnected },
                set: { keep in
                    if let display { DisplayPowerController.shared.setKeepDisconnected(keep, for: display) } else {
                        store.updateDisplay(key) { $0.keepDisconnected = keep }
                    }
                }))
            Button("Забыть все настройки этого дисплея", role: .destructive) {
                store.update { $0.displays[key] = nil }
                if let display { GammaController.shared.apply(display) }
                ScalingController.shared.reconcile()
            }
        }
    }
}

// MARK: - Hotkeys

private struct HotkeySettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HotkeyField(action: action, binding: store.value.hotkeys.first { $0.action == action }) { newBinding in
                            store.update { settings in
                                settings.hotkeys.removeAll { $0.action == action }
                                if let newBinding {
                                    settings.hotkeys.removeAll { $0.keyCode == newBinding.keyCode && $0.modifiers == newBinding.modifiers }
                                    settings.hotkeys.append(newBinding)
                                }
                            }
                            HotkeyCenter.shared.reload()
                        }
                        .frame(width: 170, height: 24)
                    }
                }
            } footer: {
                Text("Щёлкните поле и нажмите сочетание с ⌘, ⌥ или ⌃ (или F1–F19). ⌫ — очистить, ⎋ — отмена. Действуют на дисплей, выбранный во вкладке «Основные».")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyField: NSViewRepresentable {
    let action: HotkeyAction
    let binding: HotkeyBinding?
    let onChange: (HotkeyBinding?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        HotkeyRecorderButton()
    }

    func updateNSView(_ view: HotkeyRecorderButton, context: Context) {
        view.hotkeyAction = action
        view.current = binding
        view.onChange = onChange
        view.refresh()
    }
}

final class HotkeyRecorderButton: NSButton {
    var hotkeyAction = HotkeyAction.brightnessUp
    var current: HotkeyBinding?
    var onChange: ((HotkeyBinding?) -> Void)?
    private var isRecording = false

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        isRecording = true
        HotkeyCenter.shared.suspend()   // otherwise an existing shortcut would fire instead of being recorded
        window?.makeFirstResponder(self)
        refresh()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        HotkeyCenter.shared.reload()
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            stopRecording()
            return
        }
        if code == kVK_Delete || code == kVK_ForwardDelete {
            stopRecording()
            onChange?(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty || Self.functionKeys.contains(code) else {
            NSSound.beep()
            return
        }
        stopRecording()
        onChange?(HotkeyBinding(action: hotkeyAction, keyCode: UInt32(code), modifiers: KeyNames.carbonModifiers(flags)))
    }

    func refresh() {
        title = isRecording
            ? "Нажмите сочетание…"
            : current.map { KeyNames.describe(keyCode: $0.keyCode, modifiers: $0.modifiers) } ?? "Не задано"
    }
}

// MARK: - Virtual screens

private struct VirtualScreenSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            if !VirtualScreenController.shared.isSupported {
                Text("Виртуальные экраны недоступны в этой версии macOS.").foregroundStyle(.secondary)
            }
            ForEach(store.value.virtualScreens) { config in
                VirtualScreenEditor(original: config)
            }
            Section {
                Button("Добавить виртуальный экран") {
                    VirtualScreenController.shared.add(VirtualScreenConfig())
                }
            } footer: {
                Text("Виртуальный экран виден системе как настоящий монитор: его можно транслировать в окно (картинка в картинке), показывать в видеозвонках и при удалённом доступе.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VirtualScreenEditor: View {
    let original: VirtualScreenConfig
    @State private var draft: VirtualScreenConfig
    @State private var isRunning: Bool

    init(original: VirtualScreenConfig) {
        self.original = original
        _draft = State(initialValue: original)
        _isRunning = State(initialValue: VirtualScreenController.shared.isRunning(original.id))
    }

    var body: some View {
        let controller = VirtualScreenController.shared
        Section(original.name) {
            TextField("Название", text: $draft.name)
            HStack {
                TextField("Ширина", value: $draft.width, format: .number.grouping(.never))
                Text("×")
                TextField("Высота", value: $draft.height, format: .number.grouping(.never))
            }
            Toggle("HiDPI (рендеринг в 2×)", isOn: $draft.hiDPI)
            Picker("Частота", selection: $draft.refreshRate) {
                ForEach([24.0, 30, 50, 60, 75, 90, 120, 144], id: \.self) { Text("\(Int($0)) Гц").tag($0) }
            }
            Toggle("Включать при запуске Ekran", isOn: $draft.launchAutomatically)
            HStack {
                Button("Сохранить") {
                    draft.width = draft.width.clamped(to: 640 ... 8192)
                    draft.height = draft.height.clamped(to: 480 ... 8192)
                    controller.update(draft)
                }
                .disabled(draft == original)
                Button(isRunning ? "Выключить" : "Включить") {
                    if isRunning { controller.stop(original.id) } else { controller.start(original) }
                    isRunning = controller.isRunning(original.id)
                }
                if isRunning, let id = controller.displayID(for: original.id) {
                    Button("Картинка в картинке") { StreamController.shared.streamDisplay(id, title: original.name) }
                }
                Spacer()
                Button("Удалить", role: .destructive) { controller.remove(original.id) }
            }
        }
    }
}

// MARK: - Automation

private struct AutomationSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("URL-схема") {
                CodeLine("open -g \"ekran://brightness?display=main&value=70\"")
                CodeLine("open -g \"ekran://scale?display=external&width=1920\"")
                CodeLine("open -g \"ekran://preset?name=Работа\"")
                Text("Подходит для «Команд», Raycast, Alfred, BetterTouchTool и Stream Deck.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Командная строка") {
                CodeLine("sudo ln -sf /Applications/Ekran.app/Contents/Resources/ekranctl /usr/local/bin/ekranctl")
                CodeLine("ekranctl list")
                CodeLine("ekranctl volume display=mouse delta=-10")
            }
            Section("HTTP API") {
                Toggle("Включить (только 127.0.0.1)", isOn: store.binding(\.httpEnabled) { _ in HTTPServer.shared.reload() })
                TextField("Порт", value: store.binding(\.httpPort) { _ in HTTPServer.shared.reload() }, format: .number.grouping(.never))
                TextField("Токен (необязательно)", text: store.binding(\.httpToken))
                CodeLine("curl \"http://127.0.0.1:\(store.value.httpPort)/get?display=main\"")
            }
            Section("Команды") {
                Text(CommandRouter.help)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CodeLine: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Скопировать")
        }
    }
}

// MARK: - About

private struct AboutView: View {
    @State private var conflicts = AppController.conflictingApps

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ekran").font(.title2.bold())
                        Text("Версия \(version)").foregroundStyle(.secondary)
                        Text("HiDPI-масштабирование, DDC, XDR, виртуальные экраны и автоматизация для мониторов Mac.")
                            .font(.callout)
                    }
                }
            }
            if !conflicts.isEmpty {
                Section("Возможные конфликты") {
                    Label("Запущено: \(conflicts.joined(separator: ", ")). Такие программы тоже меняют гамму, яркость и виртуальные дисплеи — лучше закрыть их или отключить в них пересекающиеся функции.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("Как это работает") {
                Text("• Масштаб: скрытый виртуальный дисплей рисует рабочий стол в 2×, физический монитор его зеркалирует — получается чёткий HiDPI любого размера.")
                Text("• Яркость: встроенные экраны и мониторы Apple — через DisplayServices, внешние — по DDC/CI, остальные — программно через гамма-таблицу (без нагрузки на GPU).")
                Text("• Все изменения конфигурации привязаны к процессу: если Ekran закроется, дисплеи вернутся в исходное состояние.")
            }
            .font(.callout)
            Section {
                Button("Сбросить все настройки…", role: .destructive) {
                    guard Dialogs.confirm(title: "Сбросить все настройки?", message: "Масштабирование, пресеты, горячие клавиши и виртуальные экраны будут удалены.", action: "Сбросить") else { return }
                    VirtualScreenController.shared.stopAll()
                    SettingsStore.shared.update { $0 = AppSettings() }
                    ScalingController.shared.reconcile()
                    GammaController.shared.reloadAll()
                    XDRController.shared.sync()
                    RefreshKeeper.shared.sync()
                    HotkeyCenter.shared.reload()
                    MediaKeyTap.shared.stop()
                    HTTPServer.shared.reload()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { conflicts = AppController.conflictingApps }
    }
}
