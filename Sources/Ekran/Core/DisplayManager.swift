import AppKit

struct DisplayChanges {
    var added: [Display] = []
    var removed: [Display] = []
    var isInitial = false
}

/// Keeps the list of online displays. Purely event driven: CoreGraphics reconfiguration callbacks
/// and wake notifications trigger a debounced refresh, nothing is polled.
final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var displays: [Display] = []
    var onChange: ((DisplayChanges) -> Void)?
    private let refreshDebouncer = Debouncer(delay: 0.3)
    private var wakeObservers: [NSObjectProtocol] = []

    func start() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            })
        }
        refresh(initial: true)
    }

    func scheduleRefresh() {
        refreshDebouncer.schedule { [weak self] in self?.refresh(initial: false) }
    }

    func refresh(initial: Bool = false) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return }

        var changes = DisplayChanges(isInitial: initial)
        var next: [Display] = []
        for id in ids.prefix(Int(count)) {
            if let existing = displays.first(where: { $0.id == id }),
               existing.vendor == CGDisplayVendorNumber(id), existing.model == CGDisplayModelNumber(id),
               existing.serial == CGDisplaySerialNumber(id) {
                existing.modeCache = nil
                existing.refreshName()
                next.append(existing)
            } else {
                let display = Display(id: id)
                next.append(display)
                changes.added.append(display)
            }
        }
        changes.removed = displays.filter { old in !next.contains { $0 === old } }
        displays = next.sorted { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
            return lhs.id < rhs.id
        }
        if !changes.added.isEmpty || !changes.removed.isEmpty {
            Log.display.info("displays: +\(changes.added.map(\.name)) -\(changes.removed.map(\.name))")
        }
        onChange?(changes)
    }

    func display(id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    func display(key: String) -> Display? {
        displays.first { $0.key == key && $0.kind != .scalingBackend }
    }

    /// Displays shown to the user (scaling backends are represented by their physical display).
    var visible: [Display] {
        displays.filter { $0.kind != .scalingBackend }
    }

    var physical: [Display] {
        displays.filter { $0.kind == .physical }
    }

    /// Maps a scaling backend to the physical display it drives; other displays map to themselves.
    func owner(of display: Display) -> Display {
        if display.kind == .scalingBackend, let physical = ScalingController.shared.physicalDisplay(forBackend: display.id) {
            return physical
        }
        return display
    }

    var main: Display? {
        displays.first(where: \.isMain).map(owner(of:))
    }

    var underMouse: Display? {
        guard let screen = NSScreen.underMouse, let display = display(id: screen.displayID) else { return main }
        return owner(of: display)
    }

    /// Resolves the display set a keyboard or automation command should act on.
    func targets(for target: KeyTarget) -> [Display] {
        switch target {
        case .mouse: underMouse.map { [$0] } ?? []
        case .main: main.map { [$0] } ?? []
        case .all: visible.filter { $0.kind == .physical }
        }
    }
}

private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async { DisplayManager.shared.scheduleRefresh() }
}
