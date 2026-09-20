import AppKit
import AVFoundation
import ScreenCaptureKit

/// Picture-in-picture: streams a display (e.g. a virtual screen) or a single window into a floating window.
/// ScreenCaptureKit delivers IOSurface-backed frames only when content changes, and they are shown zero-copy
/// through AVSampleBufferDisplayLayer.
final class StreamController {
    static let shared = StreamController()

    private var windows: [StreamWindow] = []

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        Dialogs.info(
            title: "Нужен доступ к записи экрана",
            message: "Разрешите Ekran в «Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука», затем повторите.")
        return false
    }

    func streamDisplay(_ displayID: CGDirectDisplayID, title: String) {
        guard ensurePermission() else { return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Dialogs.info(title: "Не удалось начать трансляцию", message: error?.localizedDescription ?? "Дисплей недоступен.")
                    return
                }
                // Exclude our own PIP windows to avoid an infinite mirror.
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let scale = NSScreen.screen(for: displayID)?.backingScaleFactor ?? 2
                let size = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
                self.open(filter: filter, pixelSize: size, title: title)
            }
        }
    }

    func availableWindows(completion: @escaping ([SCWindow]) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            completion([])
            return
        }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            let pid = ProcessInfo.processInfo.processIdentifier
            let windows = (content?.windows ?? []).filter {
                $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
                    && $0.owningApplication?.processID != pid && !($0.title ?? "").isEmpty
            }
            DispatchQueue.main.async { completion(windows) }
        }
    }

    func streamWindow(_ window: SCWindow) {
        guard ensurePermission() else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        let app = window.owningApplication?.applicationName ?? ""
        open(filter: filter, pixelSize: size, title: [app, window.title ?? ""].filter { !$0.isEmpty }.joined(separator: " — "))
    }

    func requestPermission() {
        _ = ensurePermission()
    }

    private func open(filter: SCContentFilter, pixelSize: CGSize, title: String) {
        let window = StreamWindow(filter: filter, pixelSize: pixelSize, title: title) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        windows.append(window)
        window.start()
    }
}

private final class StreamWindow: NSObject, NSWindowDelegate, SCStreamOutput, SCStreamDelegate {
    private let window: NSWindow
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let filter: SCContentFilter
    private let pixelSize: CGSize
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.ekran.stream", qos: .userInteractive)
    private let onClose: (StreamWindow) -> Void

    init(filter: SCContentFilter, pixelSize: CGSize, title: String, onClose: @escaping (StreamWindow) -> Void) {
        self.filter = filter
        self.pixelSize = pixelSize
        self.onClose = onClose
        let aspect = pixelSize.width / max(pixelSize.height, 1)
        let height: CGFloat = 360
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: height * aspect, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = title.isEmpty ? "Трансляция" : title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: pixelSize.width, height: pixelSize.height)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.delegate = self
        window.sharingType = .none

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(displayLayer)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func start() {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            fail(error)
            return
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            if let error { DispatchQueue.main.async { self?.fail(error) } }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete
        else { return }

        if let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true), CFArrayGetCount(array) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if #available(macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.fail(error) }
    }

    private func fail(_ error: Error) {
        Log.general.error("stream stopped: \(error.localizedDescription)")
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        onClose(self)
    }
}
