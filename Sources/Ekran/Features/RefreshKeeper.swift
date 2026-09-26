import AppKit
import CoreVideo
import Metal
import QuartzCore

/// "Keep full refresh rate": makes WindowServer composite a display on every vsync.
///
/// Fixes video (YouTube in a browser, for example) that plays at a visibly lower, uneven frame rate on an external
/// monitor, often a high refresh one or one that mirrors a scaling backend, and turns smooth as soon as the cursor
/// moves. The moving cursor makes the compositor redraw every frame; a 1-point, practically transparent window
/// redrawn on every vsync does the same without the cursor.
/// It costs a tiny GPU pass per frame and keeps the display from idling, so it is off by default, runs only on the
/// displays where it is enabled and stops while the screens sleep.
final class RefreshKeeper {
    static let shared = RefreshKeeper()

    private var pacers: [CGDirectDisplayID: FramePacer] = [:]
    private lazy var device = MTLCreateSystemDefaultDevice()
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false

    var isSupported: Bool { device != nil }

    func isActive(on display: Display) -> Bool {
        pacers[display.id] != nil
    }

    func setEnabled(_ enabled: Bool, for display: Display) {
        display.updateSettings { $0.keepFullRefreshRate = enabled }
        sync()
    }

    func sync() {
        observeSleep()
        var wanted: [CGDirectDisplayID: NSScreen] = [:]
        if !screensAsleep {
            for display in DisplayManager.shared.physical where display.settings.keepFullRefreshRate {
                // While scaled through a backend the desktop lives on the backend's screen.
                let screenID = ScalingController.shared.backendID(for: display) ?? display.id
                if let screen = NSScreen.screen(for: screenID) ?? display.screen { wanted[display.id] = screen }
            }
        }
        for (id, pacer) in pacers where wanted[id] == nil {
            pacer.close()
            pacers[id] = nil
        }
        guard let device else { return }
        for (id, screen) in wanted {
            if let pacer = pacers[id] {
                pacer.move(to: screen)
            } else if let pacer = FramePacer(displayID: id, screen: screen, device: device) {
                pacers[id] = pacer
                Log.display.info("keeping full refresh rate on display \(id)")
            }
        }
    }

    func stopAll() {
        pacers.values.forEach { $0.close() }
        pacers.removeAll()
    }

    private func observeSleep() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
            self?.sync()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
            self?.sync()
        })
    }
}

/// A 1-point window in the corner of a screen whose Metal layer presents a new frame on every vsync of the display.
private final class FramePacer {
    private let window: NSWindow
    private let renderer: Renderer
    private var link: CVDisplayLink?

    init?(displayID: CGDirectDisplayID, screen: NSScreen, device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &created) == kCVReturnSuccess, let link = created else { return nil }

        window = NSWindow(contentRect: NSRect(origin: screen.frame.origin, size: NSSize(width: 1, height: 1)),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Above full-screen apps: a covered window would not make the compositor redraw that space.
        window.level = .screenSaver
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: 1, height: 1)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        window.setFrameOrigin(screen.frame.origin)
        window.orderFrontRegardless()

        renderer = Renderer(layer: layer, queue: queue)
        let renderer = renderer
        CVDisplayLinkSetOutputHandler(link) { _, _, _, _, _ in
            renderer.render()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        self.link = link
    }

    func move(to screen: NSScreen) {
        if window.frame.origin != screen.frame.origin { window.setFrameOrigin(screen.frame.origin) }
    }

    func close() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        window.orderOut(nil)
        window.close()
    }

    deinit {
        if let link { CVDisplayLinkStop(link) }
    }
}

/// Runs on the display link thread. The pixel alternates between two barely-there shades so every frame differs.
private final class Renderer {
    private let layer: CAMetalLayer
    private let queue: MTLCommandQueue
    private var odd = false

    init(layer: CAMetalLayer, queue: MTLCommandQueue) {
        self.layer = layer
        self.queue = queue
    }

    func render() {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        odd.toggle()
        let alpha = odd ? 0.004 : 0.008
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: alpha)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
