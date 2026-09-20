import AppKit

enum Dialogs {
    static func info(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func text(title: String, message: String, initial: String = "", placeholder: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Asks for a size such as "1920x1080"; a single number is accepted as width when `widthOnly` is set.
    static func size(title: String, message: String, initial: String, widthOnly: Bool = false) -> (width: Int, height: Int?)? {
        guard let text = text(title: title, message: message, initial: initial, placeholder: widthOnly ? "1920" : "1920×1080") else {
            return nil
        }
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let width = numbers.first, (640 ... 8192).contains(width) else { return nil }
        let height = numbers.count > 1 ? numbers[1] : nil
        if !widthOnly, height == nil { return nil }
        return (width, height)
    }
}
