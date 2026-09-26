import AppKit
import ColorSync
import Combine

final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    private var statusMenu: StatusMenuController?
    private var observers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?

    /// Other display utilities that fight over the same gamma tables, virtual displays or DDC bus.
    static var conflictingApps: [String] {
        let known: Set<String> = ["BetterDisplay", "MonitorControl", "Lunar", "BrightIntosh", "Vivid", "SwitchResX", "DeskPad"]
        return NSWorkspace.shared.runningApplications.compactMap(\.localizedName).filter(known.contains)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        statusMenu = StatusMenuController()

        let manager = DisplayManager.shared
        manager.onChange = { [weak self] changes in self?.displaysChanged(changes) }
        manager.start()

        VirtualScreenController.shared.startAutomatic()
        HotkeyCenter.shared.reload()
        if SettingsStore.shared.value.mediaKeysEnabled {
            // The helper asks for the permission once by itself; afterwards the menu offers it.
            let firstTime = !SettingsStore.shared.value.keyHelperPrompted
            if firstTime { SettingsStore.shared.update { $0.keyHelperPrompted = true } }
            MediaKeyTap.shared.start(prompt: firstTime)
        }
        HTTPServer.shared.reload()
        CommandBridge.startListening()
        settingsSubscription = SettingsStore.shared.$value
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { _ in MediaKeyTap.shared.refreshSnapshot() }

        // A colour profile change rebuilds the gamma tables; our adjustments are recomposed on top.
        let profileChanged = Notification.Name(kColorSyncDeviceProfilesNotification.takeUnretainedValue() as String)
        observers.append(DistributedNotificationCenter.default().addObserver(forName: profileChanged, object: nil, queue: .main) { _ in
            GammaController.shared.reloadAll()
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsStore.shared.flush()
        ScalingController.shared.teardownAll()
        VirtualScreenController.shared.stopAll()
        DisplayPowerController.shared.reconnectAll()
        GammaController.shared.resetAll()
        RefreshKeeper.shared.stopAll()
        MediaKeyTap.shared.stop()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        let response = CommandRouter.execute(url: url)
        if response["ok"] as? Bool == false {
            Log.automation.error("URL command failed: \(String(describing: response["error"] ?? ""))")
        }
    }

    // MARK: Display events

    private func displaysChanged(_ changes: DisplayChanges) {
        let manager = DisplayManager.shared
        if changes.isInitial || !changes.added.isEmpty {
            attachDDC(to: manager.physical.filter { $0.ddc == nil })
        }
        ScalingController.shared.reconcile()
        VirtualScreenController.shared.applyPendingModes()
        GammaController.shared.reloadAll()
        XDRController.shared.sync()
        RefreshKeeper.shared.sync()
        BrightnessController.shared.updateSync()
        LayoutProtection.shared.scheduleCheck()
        if SettingsStore.shared.value.mediaKeysEnabled { MediaKeyTap.shared.refreshSnapshot() }
        DisplayPowerController.shared.enforce(added: changes.isInitial ? manager.physical : changes.added.filter { $0.kind == .physical })
        ScriptRunner.displaysChanged(changes)
        statusMenu?.refreshIfOpen()
    }

    private func attachDDC(to displays: [Display]) {
        let channels = DDCChannel.discover(for: displays)
        for display in displays {
            guard let channel = channels[display.id] else { continue }
            display.ddc = channel
            BrightnessController.shared.refreshHardwareValues(for: display)
        }
    }

    func rediscoverDDC() {
        let displays = DisplayManager.shared.physical
        displays.forEach { $0.ddc = nil }
        attachDDC(to: displays)
        MediaKeyTap.shared.refreshSnapshot()
        statusMenu?.refreshIfOpen()
    }

    /// The main display is the one at the global origin, so every display is shifted by the new main's origin.
    func makeMain(_ display: Display) {
        let scaling = ScalingController.shared
        let targetID = scaling.isActive(display) ? scaling.backendID(for: display) ?? display.id : display.id
        let origin = CGDisplayBounds(targetID).origin
        guard origin != .zero else { return }
        let arranged = DisplayManager.shared.displays.filter(\.isArranged)
        configureDisplays(.permanently) { config in
            for item in arranged {
                let bounds = item.bounds
                CGConfigureDisplayOrigin(config, item.id, Int32(bounds.minX - origin.x), Int32(bounds.minY - origin.y))
            }
            return true
        }
    }
}
