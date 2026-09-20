import AppKit
import CPrivate

/// Compact on-screen indicator shown on the display that was changed.
final class OSD {
    static let shared = OSD()

    enum Kind {
        case brightness, contrast, volume, mute, xdr
        case text(String, symbol: String)

        var symbol: String {
            switch self {
            case .brightness: "sun.max.fill"
            case .contrast: "circle.lefthalf.filled"
            case .volume: "speaker.wave.2.fill"
            case .mute: "speaker.slash.fill"
            case .xdr: "sun.max.trianglebadge.exclamationmark.fill"
            case let .text(_, symbol): symbol
            }
        }
    }

    private var panels: [CGDirectDisplayID: OSDPanel] = [:]

    func show(_ kind: Kind, value: Double? = nil, on display: Display) {
        guard SettingsStore.shared.value.showOSD else { return }
        // A mirrored (scaled) display has no NSScreen of its own; use the screen that is drawn on it.
        let screen = display.screen
            ?? NSScreen.screen(for: ScalingController.shared.backendID(for: display) ?? kCGNullDirectDisplay)
            ?? NSScreen.main
        guard let screen else { return }
        let panel = panels[screen.displayID] ?? OSDPanel()
        panels[screen.displayID] = panel
        panel.show(kind, value: value, on: screen)
    }
}

private final class OSDPanel {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bar = LevelBar()
    private var hideWork: DispatchWorkItem?

    private static let height: CGFloat = 46

    /// Liquid Glass on macOS 26, the older blur material below it.
    private static func makeBackground() -> NSView {
        if let glass = EKCreateGlassView(height / 2) { return glass }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = height / 2
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return effect
    }

    init() {
        let background = Self.makeBackground()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: Self.height), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Glass draws its own edge and shadow; a window shadow on top of that looks heavy.
        panel.hasShadow = background is NSVisualEffectView
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        background.frame = panel.contentRect(forFrameRect: panel.frame)
        let content = NSView(frame: background.bounds)
        content.autoresizingMask = [.width, .height]

        icon.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        icon.contentTintColor = .labelColor
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.alignment = .right
        label.textColor = .labelColor

        for view in [icon, bar, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            bar.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            bar.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
        ])
        // The glass view hosts its content; the blur material just takes a subview.
        if background is NSVisualEffectView {
            background.addSubview(content)
        } else {
            background.setValue(content, forKey: "contentView")
        }
        panel.contentView = background
    }

    func show(_ kind: OSD.Kind, value: Double?, on screen: NSScreen) {
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        if case let .text(text, _) = kind {
            bar.isHidden = true
            label.stringValue = text
            label.alignment = .left
        } else {
            bar.isHidden = value == nil
            bar.value = value ?? 0
            label.alignment = .right
            label.stringValue = value.map { kind.isXDR ? String(format: "%.0f%%", $0 * 100) : percent($0) } ?? ""
        }
        let width: CGFloat = bar.isHidden ? max(160, label.intrinsicContentSize.width + 70) : 260
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - width - 12, y: visible.maxY - Self.height - 10, width: width, height: Self.height)
        panel.setFrame(frame, display: true)

        hideWork?.cancel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else if panel.alphaValue < 1 {
            panel.alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

private extension OSD.Kind {
    var isXDR: Bool {
        if case .xdr = self { return true }
        return false
    }
}

private final class LevelBar: NSView {
    var value = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let fraction = value.clamped(to: 0 ... 1)
        guard fraction > 0 else { return }
        // Never narrower than a dot, so low values still read as a rounded cap.
        let width = max(bounds.height, bounds.width * fraction)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
