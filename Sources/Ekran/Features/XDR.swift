import AppKit
import Metal
import QuartzCore

/// Brightness above the SDR limit on XDR/HDR panels.
/// A 1-point EDR window keeps the panel in extended range and the gamma table is scaled above 1.0.
/// The timer only exists while the feature is enabled on at least one display.
final class XDRController {
    static let shared = XDRController()

    /// XDR panels sustain roughly twice their SDR luminance full-screen; more only clips highlights.
    static let maxBoost = 2.0

    private var triggers: [CGDirectDisplayID: EDRTrigger] = [:]
    private var timer: Timer?
    private lazy var device = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue = device?.makeCommandQueue()

    func isSupported(_ display: Display) -> Bool {
        display.kind == .physical && display.edrPotential > 1.01 && device != nil
    }

    func isActive(on display: Display) -> Bool {
        triggers[display.id] != nil
    }

    /// Currently available headroom (grows once EDR is engaged).
    func headroom(for display: Display) -> Double {
        Double(display.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
    }

    func setEnabled(_ enabled: Bool, for display: Display) {
        display.updateSettings { $0.xdrEnabled = enabled }
        sync()
    }

    func setBoost(_ boost: Double, for display: Display) {
        display.updateSettings { $0.xdrBoost = boost }
        GammaController.shared.apply(display)
    }

    func sync() {
        let wanted = DisplayManager.shared.physical.filter { $0.settings.xdrEnabled && isSupported($0) && $0.screen != nil }
        let wantedIDs = Set(wanted.map(\.id))
        for (id, trigger) in triggers where !wantedIDs.contains(id) {
            trigger.close()
            triggers[id] = nil
            if let display = DisplayManager.shared.display(id: id) { GammaController.shared.apply(display) }
        }
        guard let device, let commandQueue else { return }
        for display in wanted {
            guard let screen = display.screen else { continue }
            if let trigger = triggers[display.id] {
                trigger.move(to: screen)
            } else {
                let trigger = EDRTrigger(screen: screen, device: device)
                trigger.render(queue: commandQueue)
                triggers[display.id] = trigger
            }
        }
        if triggers.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        // Give the compositor a moment to raise the headroom before boosting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            wanted.forEach(GammaController.shared.apply)
        }
    }

    private func tick() {
        guard let commandQueue else { return }
        for trigger in triggers.values { trigger.render(queue: commandQueue) }
        for id in triggers.keys {
            if let display = DisplayManager.shared.display(id: id) { GammaController.shared.verify(display) }
        }
    }
}

private final class EDRTrigger {
    private let window: NSWindow
    private let layer = CAMetalLayer()

    init(screen: NSScreen, device: MTLDevice) {
        window = NSWindow(contentRect: NSRect(origin: screen.frame.origin, size: NSSize(width: 1, height: 1)),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: 1, height: 1)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        window.setFrameOrigin(screen.frame.origin)
        window.orderFrontRegardless()
    }

    func move(to screen: NSScreen) {
        if window.frame.origin != screen.frame.origin { window.setFrameOrigin(screen.frame.origin) }
    }

    func render(queue: MTLCommandQueue) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1.6, green: 1.6, blue: 1.6, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
