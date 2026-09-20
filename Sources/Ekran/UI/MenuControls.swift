import AppKit

/// Slider row embedded in an NSMenu.
final class MenuSliderView: NSView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private let onChange: (Double) -> Void
    private let onCommit: ((Double) -> Void)?
    private var pendingCommit: Double?

    /// `showsValue` false gives the whole row to the slider, for values a plain percentage does not explain.
    /// `onChange` fires while dragging; `onCommit` (if set) only when the mouse is released.
    init(symbol: String, value: Double, range: ClosedRange<Double>, tickCount: Int = 0, width: CGFloat = 290,
         showsValue: Bool = true, format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void,
         onCommit: ((Double) -> Void)? = nil) {
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        self.format = format
        self.onChange = onChange
        self.onCommit = onCommit
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))

        let icon = NSImageView(image: NSImage.symbol(symbol, size: 13) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed(_:))
        if tickCount > 1 {
            slider.numberOfTickMarks = tickCount
            slider.allowsTickMarkValuesOnly = true
            slider.tickMarkPosition = .below
        }
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.stringValue = format(value)

        for view in ([icon, slider] + (showsValue ? [valueLabel] : [])) as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            slider.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if showsValue {
            constraints += [
                valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
                valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                valueLabel.widthAnchor.constraint(equalToConstant: 76),
            ]
        } else {
            constraints.append(slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed(_ sender: NSSlider) {
        let value = sender.doubleValue
        valueLabel.stringValue = format(value)
        onChange(value)
        guard let onCommit else { return }
        if NSApp.currentEvent?.type == .leftMouseUp {
            pendingCommit = nil
            onCommit(value)
        } else {
            pendingCommit = value
        }
    }

    /// Keyboard or scroll changes (and a missed mouse-up) are committed when the menu closes.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let value = pendingCommit {
            pendingCommit = nil
            onCommit?(value)
        }
    }

    /// Shows a value that changed elsewhere, unless the user is dragging this slider right now.
    func show(_ value: Double) {
        guard NSEvent.pressedMouseButtons & 1 == 0 || window == nil else { return }
        slider.doubleValue = value
        valueLabel.stringValue = format(value)
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = self
        return item
    }
}

final class LazyMenuDelegate: NSObject, NSMenuDelegate {
    private let build: (NSMenu) -> Void

    init(_ build: @escaping (NSMenu) -> Void) {
        self.build = build
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        build(menu)
    }
}

/// Menu item whose action is a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
        if let symbol { image = NSImage.symbol(symbol) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, key: String = "",
             handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, symbol: symbol, checked: checked, enabled: enabled, key: key, handler: handler)
        addItem(item)
        return item
    }

    @discardableResult
    func addSubmenu(_ title: String, symbol: String? = nil, build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage.symbol(symbol) }
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        build(submenu)
        item.submenu = submenu
        addItem(item)
        return item
    }

    /// Submenu whose content is built only when it is about to open (and rebuilt on every open).
    @discardableResult
    func addLazySubmenu(_ title: String, symbol: String? = nil, build: @escaping (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage.symbol(symbol) }
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        let delegate = LazyMenuDelegate(build)
        submenu.delegate = delegate
        item.representedObject = delegate  // NSMenu holds its delegate weakly
        submenu.addItem(NSMenuItem(title: "…", action: nil, keyEquivalent: ""))
        item.submenu = submenu
        addItem(item)
        return item
    }

    func addHeader(_ title: String) {
        if #available(macOS 14.0, *) {
            addItem(.sectionHeader(title: title))
        } else {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            item.isEnabled = false
            addItem(item)
        }
    }

    func addNote(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        addItem(item)
    }
}
