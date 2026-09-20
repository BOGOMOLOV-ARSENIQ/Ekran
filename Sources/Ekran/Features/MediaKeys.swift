import AppKit
import Combine
import CoreAudio

/// Brightness and volume keys for external monitors.
///
/// The event tap itself lives in the tiny "Ekran Keys" helper (Sources/KeyTap). macOS ties the Accessibility
/// permission to the exact signature of the process that owns the tap; build.sh builds the helper once and reuses
/// it, so rebuilding Ekran keeps the permission. Ekran tells the helper which displays it handles and performs the
/// key presses the helper reports. No helper runs unless the feature is enabled and a display needs it.
final class MediaKeyTap: ObservableObject {
    static let shared = MediaKeyTap()

    enum Status: Equatable {
        case off              // feature disabled
        case idle             // nothing to control (e.g. only Apple displays connected)
        case starting
        case needsPermission
        case active
        case unavailable      // helper missing or failed to start
    }

    @Published private(set) var status = Status.off

    private enum Name {
        static let state = Notification.Name("app.ekran.keytap.state")
        static let command = Notification.Name("app.ekran.keytap.command")
        static let press = Notification.Name("app.ekran.keytap.press")
        static let status = Notification.Name("app.ekran.keytap.status")
    }

    private static let helperBundleID = "app.ekran.Ekran.KeyTap"
    private static let brightnessUp = 2, brightnessDown = 3, soundUp = 0, soundDown = 1, mute = 7

    private let token = UUID().uuidString
    private var helper: NSRunningApplication?
    /// Whether the running helper has reported in, i.e. is certainly listening for Ekran's messages.
    private var helperAcknowledged = false
    private var launching = false
    private var restarts: [Date] = []
    private var desiredState: NSDictionary?
    private var sentState: NSDictionary?
    private var volumeDisplay: CGDirectDisplayID?
    private var observers: [NSObjectProtocol] = []
    private var audioListener: AudioObjectPropertyListenerBlock?

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Ekran Keys.app")
    }

    var helperPID: pid_t? { helper?.processIdentifier }

    func setEnabled(_ enabled: Bool) {
        SettingsStore.shared.update {
            $0.mediaKeysEnabled = enabled
            if enabled { $0.keyHelperPrompted = true }
        }
        if enabled { start(prompt: true) } else { refreshSnapshot() }
    }

    /// `prompt` shows the system permission dialog if the helper is not allowed yet.
    func start(prompt: Bool) {
        observe()
        refreshSnapshot(prompt: prompt)
    }

    func stop() {
        stopHelper()
        setStatus(.off)
    }

    /// Shows the permission dialog for the helper and opens the Accessibility settings.
    func requestPermission() {
        if helper == nil {
            refreshSnapshot(prompt: true)
        } else {
            send(Name.command, ["command": "prompt"])
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Asks the helper to check its permission again (cheap; called when the menu opens).
    func recheck() {
        guard helper != nil, status == .needsPermission else { return }
        send(Name.command, ["command": "check"])
    }

    /// Call after display, DDC, brightness-method or keyboard setting changes.
    func refreshSnapshot(prompt: Bool = false) {
        let settings = SettingsStore.shared.value
        guard settings.mediaKeysEnabled else {
            if helper != nil || status != .off { stop() }
            return
        }
        observe()

        let brightness = BrightnessController.shared
        var displays: [NSNumber] = []
        for display in DisplayManager.shared.physical where !display.hasAppleBrightness && brightness.supports(.brightness, on: display) {
            displays.append(NSNumber(value: display.id))
            // While scaled, the cursor is on the mirroring backend rather than on the monitor itself.
            if let backend = ScalingController.shared.backendID(for: display) { displays.append(NSNumber(value: backend)) }
        }
        volumeDisplay = settings.mediaKeysControlVolume ? Self.audioDisplay()?.id : nil

        guard !displays.isEmpty || volumeDisplay != nil else {
            if helper != nil { stopHelper() }
            setStatus(.idle)
            return
        }
        let target = switch settings.keyTarget {
        case .mouse: 0
        case .main: 1
        case .all: 2
        }
        desiredState = ["enabled": true, "target": target, "displays": displays, "volume": volumeDisplay != nil]

        if helper == nil {
            launchHelper(prompt: prompt)
        } else {
            if prompt { send(Name.command, ["command": "prompt"]) }
            sendStateIfNeeded()
        }
    }

    // MARK: Helper process

    private func launchHelper(prompt: Bool) {
        guard !launching else { return }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            Log.general.error("Ekran Keys helper is missing from the app bundle")
            setStatus(.unavailable)
            return
        }
        // A helper left over from an earlier Ekran process does not know this process's token.
        for stale in NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperBundleID) {
            stale.forceTerminate()
        }
        launching = true
        sentState = nil
        helperAcknowledged = false
        if status != .needsPermission { setStatus(.starting) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        configuration.arguments = ["--parent", String(getpid()), "--token", token] + (prompt ? ["--prompt"] : [])
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launching = false
                if let error {
                    Log.general.error("Ekran Keys could not start: \(error.localizedDescription)")
                    self.setStatus(.unavailable)
                    return
                }
                self.helper = app
                self.sendStateIfNeeded()
            }
        }
    }

    private func stopHelper() {
        guard let helper else { return }
        self.helper = nil
        sentState = nil
        send(Name.command, ["command": "quit"])
        helper.terminate()
    }

    private func sendStateIfNeeded() {
        guard let desiredState, desiredState != sentState else { return }
        send(Name.state, desiredState as? [AnyHashable: Any] ?? [:])
        sentState = desiredState
    }

    private func send(_ name: Notification.Name, _ info: [AnyHashable: Any]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: token, userInfo: info, deliverImmediately: true)
    }

    private func setStatus(_ new: Status) {
        if status != new { status = new }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Name.status, object: token, queue: .main) { [weak self] note in
            self?.handleStatus(note.userInfo ?? [:])
        })
        observers.append(center.addObserver(forName: Name.press, object: token, queue: .main) { [weak self] note in
            self?.handlePress(note.userInfo ?? [:])
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let helper = self.helper, app.processIdentifier == helper.processIdentifier else { return }
            // The helper exited on its own (crash or killed): start it again, but not in a tight loop.
            self.helper = nil
            self.sentState = nil
            self.restarts = self.restarts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
            guard self.restarts.count <= 3 else {
                Log.general.error("Ekran Keys keeps exiting; not restarting it")
                self.setStatus(.unavailable)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshSnapshot() }
        })
        observeAudioOutput()
    }

    private func handleStatus(_ info: [AnyHashable: Any]) {
        let trusted = info["trusted"] as? Bool ?? false
        let tapInstalled = info["tap"] as? Bool ?? false
        if !helperAcknowledged {
            // State sent while the helper was still starting may have arrived before it listened: send it again.
            helperAcknowledged = true
            sentState = nil
        }
        sendStateIfNeeded()
        setStatus(!trusted ? .needsPermission : tapInstalled ? .active : .starting)
    }

    private func handlePress(_ info: [AnyHashable: Any]) {
        guard let key = info["key"] as? Int else { return }
        let fine = info["fine"] as? Bool ?? false
        switch key {
        case Self.brightnessUp:
            ActionPerformer.perform(.brightnessUp, fine: fine)
        case Self.brightnessDown:
            ActionPerformer.perform(.brightnessDown, fine: fine)
        case Self.soundUp, Self.soundDown, Self.mute:
            guard let id = volumeDisplay, let display = DisplayManager.shared.display(id: id) else { return }
            if key == Self.mute {
                BrightnessController.shared.toggleMute(on: [display])
            } else {
                BrightnessController.shared.step(.volume, by: key == Self.soundUp ? 1 : -1, on: [display], fine: fine)
            }
        default:
            break
        }
    }

    // MARK: Audio output

    private func observeAudioOutput() {
        guard audioListener == nil else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshSnapshot() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            audioListener = listener
        }
    }

    /// The monitor that is the current audio output (HDMI/DisplayPort audio) and can change volume over DDC.
    private static func audioDisplay() -> Display? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
        else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        let deviceName = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr
            ? (name?.takeRetainedValue() as String?) ?? "" : ""

        let candidates = DisplayManager.shared.physical.filter { $0.ddc != nil }
        if let match = candidates.first(where: {
            !deviceName.isEmpty && ($0.name.localizedCaseInsensitiveContains(deviceName) || deviceName.localizedCaseInsensitiveContains($0.name))
        }) {
            return match
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
