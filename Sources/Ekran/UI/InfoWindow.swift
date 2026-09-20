import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps SwiftUI windows alive while open and releases them (and their views) when closed.
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WindowPresenter()

    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, size: NSSize, content: () -> Content) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        DispatchQueue.main.async { self.windows[id] = nil }
    }
}

enum InfoWindowController {
    static func show(for display: Display) {
        let info = DisplayInfo(display)
        WindowPresenter.shared.show(id: "info-\(display.key)", title: display.name, size: NSSize(width: 540, height: 680)) {
            DisplayInfoView(info: info)
        }
    }
}

struct DisplayInfo {
    let name: String
    let rows: [(String, String)]
    let edid: EDID?

    init(_ display: Display) {
        name = display.name
        var rows: [(String, String)] = [
            ("Название", display.name),
            ("ID", String(display.id)),
            ("Ключ настроек", display.key),
            ("Производитель / модель", String(format: "0x%04X / 0x%04X", display.vendor, display.model)),
            ("Серийный номер", display.serial == 0 ? "—" : String(display.serial)),
            ("Тип", display.isBuiltin ? "встроенный" : display.isVirtual ? "виртуальный" : "внешний"),
        ]
        if let mode = display.currentMode {
            rows.append(("Текущий режим", "\(mode.spec.sizeTitle) точек, \(mode.spec.pixelWidth)×\(mode.spec.pixelHeight) пикселей, \(mode.spec.refreshTitle)"))
        }
        let native = display.nativePixelSize
        rows.append(("Родное разрешение", "\(native.width)×\(native.height)"))
        let size = display.physicalSizeMillimeters
        if size != .zero {
            let inches = (size.width * size.width + size.height * size.height).squareRoot() / 25.4
            let ppi = Double(native.width) / (size.width / 25.4)
            rows.append(("Физический размер", String(format: "%.0f×%.0f мм, %.1f″, %.0f ppi", size.width, size.height, inches, ppi)))
        }
        let brightness = BrightnessController.shared
        let source: String = switch brightness.brightnessSource(for: display) {
        case .apple: "Apple (DisplayServices)"
        case .ddc: "DDC/CI"
        case .software: "программная (гамма)"
        case .none: "недоступна"
        }
        rows.append(("Регулировка яркости", source))
        rows.append(("DDC/CI", display.ddc != nil ? "подключено" : "нет"))
        if display.supportsHDRToggle {
            rows.append(("HDR", DisplayPowerController.shared.isHDREnabled(display) ? "включён" : "выключен"))
        }
        if display.edrPotential > 1 {
            rows.append(("Запас яркости EDR", String(format: "до %.1f×", display.edrPotential)))
        }
        rows.append(("Гибкое масштабирование", ScalingController.shared.isActive(display) ? "активно" : "выключено"))
        if let profile = ColorProfiles.currentProfileURL(for: display) {
            rows.append(("Цветовой профиль", profile.deletingPathExtension().lastPathComponent))
        }
        self.rows = rows
        edid = display.edid.flatMap(EDID.init)
    }
}

struct DisplayInfoView: View {
    let info: DisplayInfo

    var body: some View {
        Form {
            Section("Дисплей") {
                ForEach(info.rows.indices, id: \.self) { index in
                    LabeledContent(info.rows[index].0) {
                        Text(info.rows[index].1).textSelection(.enabled)
                    }
                }
            }
            if let edid = info.edid {
                Section("EDID") {
                    let summary = edid.summary
                    ForEach(summary.indices, id: \.self) { index in
                        LabeledContent(summary[index].0) {
                            Text(summary[index].1).textSelection(.enabled)
                        }
                    }
                }
                Section("Необработанные данные (\(edid.raw.count) байт)") {
                    Text(edid.hexDump)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("Скопировать") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(edid.hexDump, forType: .string)
                        }
                        Button("Сохранить .bin…") { save(edid.raw) }
                    }
                }
            } else {
                Section("EDID") {
                    Text("Система не отдаёт EDID этого дисплея.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(info.name) EDID.bin"
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            Dialogs.info(title: "Не удалось сохранить", message: error.localizedDescription)
        }
    }
}
