import AppKit

/// One command language for the URL scheme (ekran://), the `ekranctl` CLI and the local HTTP API.
enum CommandRouter {
    typealias Response = [String: Any]

    static let help = """
    Команды (параметры через key=value, display = main|all|builtin|external|mouse|<id>|<часть имени>):
      list                                  список дисплеев
      get        display [refresh=1]        состояние дисплея (refresh — перечитать значения монитора по DDC)
      (яркость, контраст, громкость и mute принимают osd=1 — показать индикатор)
      brightness display value=0…100 | delta=±N
      contrast   display value | delta      (DDC)
      volume     display value | delta      (DDC)
      mute       display state=on|off|toggle
      dim        display value=0…100        программное затемнение (100 = без затемнения)
      scale      display width=N | step=±N | enabled=on|off|toggle | hidpi=on|off
      mode       display width=N height=N [hidpi=on|off] [refresh=N]
      hdr        display state=on|off|toggle
      xdr        display state=on|off|toggle [boost=100…200]
      input      display source=hdmi1|hdmi2|dp1|dp2|usbc|<число>
      power      display state=standby|on   (DDC)
      disconnect display | connect id=N | connect-all
      preset     name=…   | save-preset name=…
      profile    display path=/path/to.icc | reset=1
      adjust     display [contrast] [gamma] [temperature] [red] [green] [blue] [invert] [reset=1]
      virtual    action=create|remove|start|stop [name] [width] [height] [hidpi] [id]
      pip        display
      protect    state=on|off | capture=1
      http       state=on|off [port=N] [token=…]
    """

    static func execute(url: URL) -> Response {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return failure("неверный URL") }
        let command = (components.host?.isEmpty == false ? components.host : components.path.split(separator: "/").first.map(String.init)) ?? ""
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name.lowercased()] = item.value ?? "" }
        return execute(command: command, params: params)
    }

    static func execute(command: String, params: [String: String]) -> Response {
        Log.automation.info("command \(command) \(params)")
        let displays = resolve(params["display"])
        func each(_ body: (Display) -> Void) -> Response {
            guard !displays.isEmpty else { return failure("дисплей не найден") }
            displays.forEach(body)
            return ["ok": true, "displays": displays.map(\.name)]
        }
        let brightness = BrightnessController.shared

        switch command.lowercased() {
        case "list":
            return ["ok": true, "displays": DisplayManager.shared.visible.map(describe), "keys": keysStatus()]
        case "get":
            guard !displays.isEmpty else { return failure("дисплей не найден") }
            if params["refresh"] != nil {
                // Values arrive asynchronously; ask again a moment later to see what the monitor reports.
                displays.forEach { BrightnessController.shared.refreshHardwareValues(for: $0) }
            }
            return ["ok": true, "displays": displays.map(describe)]
        case "brightness":
            return each { display in
                let value = level(params, current: brightness.brightness(of: display))
                brightness.setBrightness(value, for: display)
                indicate(params, .brightness, value: value, on: display)
            }
        case "contrast":
            return each { display in
                let value = level(params, current: brightness.contrast(of: display))
                brightness.setContrast(value, for: display)
                indicate(params, .contrast, value: value, on: display)
            }
        case "volume":
            return each { display in
                let value = level(params, current: brightness.volume(of: display))
                brightness.setVolume(value, for: display)
                indicate(params, .volume, value: value, on: display)
            }
        case "mute":
            return each { display in
                let muted = flag(params["state"], current: display.settings.muted)
                brightness.setMuted(muted, for: display)
                indicate(params, muted ? .mute : .volume, value: muted ? 0 : brightness.volume(of: display), on: display)
            }
        case "dim":
            return each { brightness.setDimming(level(params, current: $0.settings.adjustments.dimming).clamped(to: 0.05 ... 1), for: $0) }
        case "scale":
            return each { display in
                let scaling = ScalingController.shared
                if let hidpi = params["hidpi"] { scaling.setHiDPI(flag(hidpi, current: display.settings.scalingHiDPI), for: display) }
                if let width = params["width"].flatMap(Int.init) {
                    if let option = scaling.options(for: display).first(where: { $0.width == width }) {
                        scaling.select(option, for: display)
                    } else {
                        scaling.addCustomWidth(width, for: display)
                    }
                } else if let step = params["step"].flatMap({ Int($0.replacingOccurrences(of: "+", with: "")) }) {
                    scaling.step(display, by: step)
                } else if let state = params["enabled"] ?? params["state"] {
                    scaling.setEnabled(flag(state, current: display.settings.scalingEnabled), for: display)
                }
            }
        case "mode":
            guard let width = params["width"].flatMap(Int.init), let height = params["height"].flatMap(Int.init) else {
                return failure("нужны width и height")
            }
            return each { display in
                let hidpi = params["hidpi"].map { flag($0, current: true) }
                let refresh = params["refresh"].flatMap(Double.init)
                let candidates = display.modes().filter {
                    $0.width == width && $0.height == height && (hidpi == nil || $0.isHiDPI == hidpi)
                }
                let mode = refresh.flatMap { rate in candidates.min { abs($0.refreshRate - rate) < abs($1.refreshRate - rate) } }
                    ?? candidates.max { $0.refreshRate < $1.refreshRate }
                if let mode { display.setMode(mode) }
            }
        case "hdr":
            return each { display in
                DisplayPowerController.shared.setHDR(flag(params["state"], current: DisplayPowerController.shared.isHDREnabled(display)), for: display)
            }
        case "xdr":
            return each { display in
                guard XDRController.shared.isSupported(display) else { return }
                if let boost = params["boost"].flatMap(Double.init) {
                    XDRController.shared.setBoost((boost / 100).clamped(to: 1 ... XDRController.maxBoost), for: display)
                }
                if let state = params["state"] { XDRController.shared.setEnabled(flag(state, current: display.settings.xdrEnabled), for: display) }
            }
        case "input":
            guard let source = params["source"], let code = inputCode(source) else { return failure("неизвестный вход") }
            return each { brightness.setInput(code, for: $0) }
        case "power":
            return each { $0.ddc?.write(.powerMode, params["state"] == "on" ? 1 : 4) }
        case "disconnect":
            return each { DisplayPowerController.shared.disconnect($0) }
        case "connect":
            guard let id = params["id"].flatMap(UInt32.init) else { return failure("нужен id") }
            return ["ok": DisplayPowerController.shared.reconnect(id)]
        case "connect-all":
            DisplayPowerController.shared.reconnectAll()
            return ["ok": true]
        case "preset":
            return ["ok": PresetController.apply(named: params["name"] ?? "")]
        case "save-preset":
            guard let name = params["name"], !name.isEmpty else { return failure("нужно name") }
            PresetController.save(name: name)
            return ["ok": true]
        case "profile":
            return each { display in
                if params["reset"] != nil {
                    ColorProfiles.setProfile(nil, for: display)
                } else if let path = params["path"] {
                    ColorProfiles.setProfile(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), for: display)
                }
            }
        case "adjust":
            return each { display in
                display.updateSettings { settings in
                    if params["reset"] != nil {
                        let dimming = settings.adjustments.dimming
                        settings.adjustments = ImageAdjustments()
                        settings.adjustments.dimming = dimming
                    }
                    if let v = params["contrast"].flatMap(Double.init) { settings.adjustments.contrast = (v / 100).clamped(to: 0.5 ... 1.5) }
                    if let v = params["gamma"].flatMap(Double.init) { settings.adjustments.gamma = v.clamped(to: 0.5 ... 2) }
                    if let v = params["temperature"].flatMap(Double.init) { settings.adjustments.temperature = (v / 100).clamped(to: -1 ... 1) }
                    if let v = params["red"].flatMap(Double.init) { settings.adjustments.red = (v / 100).clamped(to: 0 ... 1) }
                    if let v = params["green"].flatMap(Double.init) { settings.adjustments.green = (v / 100).clamped(to: 0 ... 1) }
                    if let v = params["blue"].flatMap(Double.init) { settings.adjustments.blue = (v / 100).clamped(to: 0 ... 1) }
                    if let v = params["invert"] { settings.adjustments.invert = flag(v, current: settings.adjustments.invert) }
                }
                GammaController.shared.apply(display)
            }
        case "virtual":
            return virtualScreen(params)
        case "pip":
            return each { display in
                let id = ScalingController.shared.backendID(for: display) ?? display.id
                StreamController.shared.streamDisplay(id, title: display.name)
            }
        case "protect":
            if params["capture"] != nil { LayoutProtection.shared.capture() }
            if let state = params["state"] { LayoutProtection.shared.setEnabled(flag(state, current: LayoutProtection.shared.isEnabled)) }
            return ["ok": true]
        case "http":
            SettingsStore.shared.update { settings in
                if let state = params["state"] { settings.httpEnabled = flag(state, current: settings.httpEnabled) }
                if let port = params["port"].flatMap(Int.init), (1024 ... 65535).contains(port) { settings.httpPort = port }
                if let token = params["token"] { settings.httpToken = token }
            }
            SettingsStore.shared.flush()
            HTTPServer.shared.reload()
            return ["ok": true, "enabled": SettingsStore.shared.value.httpEnabled, "port": SettingsStore.shared.value.httpPort]
        case "help", "":
            return ["ok": true, "help": help]
        default:
            return failure("неизвестная команда: \(command)")
        }
    }

    // MARK: Helpers

    /// `osd=1` makes a scripted change show the same indicator a key press would.
    private static func indicate(_ params: [String: String], _ kind: OSD.Kind, value: Double, on display: Display) {
        guard let flag = params["osd"], flag != "0", flag != "false" else { return }
        OSD.shared.show(kind, value: value, on: display)
    }

    private static func keysStatus() -> [String: Any] {
        var info: [String: Any] = ["enabled": SettingsStore.shared.value.mediaKeysEnabled, "status": "\(MediaKeyTap.shared.status)"]
        if let pid = MediaKeyTap.shared.helperPID { info["helperPID"] = pid }
        return info
    }

    static func resolve(_ selector: String?) -> [Display] {
        let manager = DisplayManager.shared
        guard let selector = selector?.trimmingCharacters(in: .whitespaces), !selector.isEmpty else {
            return manager.main.map { [$0] } ?? []
        }
        switch selector.lowercased() {
        case "main": return manager.main.map { [$0] } ?? []
        case "all": return manager.visible
        case "builtin", "internal": return manager.physical.filter(\.isBuiltin)
        case "external": return manager.physical.filter { !$0.isBuiltin }
        case "mouse", "cursor": return manager.underMouse.map { [$0] } ?? []
        default:
            if let id = UInt32(selector), let display = manager.display(id: id) { return [manager.owner(of: display)] }
            if let display = manager.display(key: selector) { return [display] }
            return manager.visible.filter { $0.name.localizedCaseInsensitiveContains(selector) }
        }
    }

    private static func level(_ params: [String: String], current: Double) -> Double {
        if let delta = params["delta"].flatMap({ Double($0.replacingOccurrences(of: "+", with: "")) }) {
            return (current + delta / 100).clamped(to: 0 ... 1)
        }
        guard let raw = params["value"] else { return current }
        if raw.hasPrefix("+") || raw.hasPrefix("-"), let delta = Double(raw.replacingOccurrences(of: "+", with: "")) {
            return (current + delta / 100).clamped(to: 0 ... 1)
        }
        return ((Double(raw) ?? current * 100) / 100).clamped(to: 0 ... 1)
    }

    private static func flag(_ raw: String?, current: Bool) -> Bool {
        switch raw?.lowercased() {
        case "1", "true", "on", "yes": true
        case "0", "false", "off", "no": false
        default: !current
        }
    }

    private static func inputCode(_ raw: String) -> UInt16? {
        let names: [String: DDCInput] = ["vga": .vga1, "dvi": .dvi1, "dvi1": .dvi1, "dvi2": .dvi2, "dp": .displayPort1,
                                         "dp1": .displayPort1, "dp2": .displayPort2, "hdmi": .hdmi1, "hdmi1": .hdmi1,
                                         "hdmi2": .hdmi2, "usbc": .usbC, "usb-c": .usbC]
        if let input = names[raw.lowercased()] { return input.rawValue }
        if raw.lowercased().hasPrefix("0x") { return UInt16(raw.dropFirst(2), radix: 16) }
        return UInt16(raw)
    }

    private static func virtualScreen(_ params: [String: String]) -> Response {
        let controller = VirtualScreenController.shared
        let config = params["id"].flatMap(UUID.init(uuidString:)).flatMap { id in controller.configs.first { $0.id == id } }
            ?? params["name"].flatMap { name in controller.configs.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
        switch params["action"]?.lowercased() {
        case "create":
            var new = VirtualScreenConfig()
            if let name = params["name"] { new.name = name }
            if let width = params["width"].flatMap(Int.init) { new.width = width }
            if let height = params["height"].flatMap(Int.init) { new.height = height }
            if let hidpi = params["hidpi"] { new.hiDPI = flag(hidpi, current: true) }
            if let refresh = params["refresh"].flatMap(Double.init) { new.refreshRate = refresh }
            controller.add(new)
            return ["ok": true, "id": new.id.uuidString]
        case "remove":
            guard let config else { return failure("виртуальный экран не найден") }
            controller.remove(config.id)
        case "start":
            guard let config else { return failure("виртуальный экран не найден") }
            controller.start(config)
        case "stop":
            guard let config else { return failure("виртуальный экран не найден") }
            controller.stop(config.id)
        default:
            let screens = controller.configs.map { config -> [String: Any] in
                ["id": config.id.uuidString, "name": config.name, "width": config.width, "height": config.height,
                 "running": controller.isRunning(config.id)]
            }
            return ["ok": true, "virtualScreens": screens]
        }
        return ["ok": true]
    }

    private static func describe(_ display: Display) -> [String: Any] {
        var info: [String: Any] = [
            "id": display.id,
            "key": display.key,
            "name": display.name,
            "builtin": display.isBuiltin,
            "main": DisplayManager.shared.main === display,
            "kind": "\(display.kind)",
        ]
        let brightness = BrightnessController.shared
        if brightness.brightnessSource(for: display) != .none {
            info["brightness"] = Int((brightness.brightness(of: display) * 100).rounded())
            info["brightnessSource"] = "\(brightness.brightnessSource(for: display))"
        }
        if display.ddc != nil {
            info["ddc"] = true
            info["contrast"] = Int((brightness.contrast(of: display) * 100).rounded())
            info["volume"] = Int((brightness.volume(of: display) * 100).rounded())
        }
        if let mode = display.currentMode {
            info["mode"] = ["width": mode.width, "height": mode.height, "pixelWidth": mode.spec.pixelWidth,
                            "pixelHeight": mode.spec.pixelHeight, "refresh": mode.refreshRate, "hidpi": mode.isHiDPI] as [String: Any]
        }
        if display.settings.scalingEnabled, let option = ScalingController.shared.currentOption(for: display) {
            info["scaling"] = ["width": option.width, "height": option.height, "active": ScalingController.shared.isActive(display)] as [String: Any]
        }
        if display.supportsHDRToggle { info["hdr"] = DisplayPowerController.shared.isHDREnabled(display) }
        if XDRController.shared.isSupported(display) { info["xdr"] = display.settings.xdrEnabled }
        return info
    }

    private static func failure(_ message: String) -> Response {
        ["ok": false, "error": message]
    }
}

// MARK: - CLI bridge (distributed notifications, no sockets needed)

enum CommandBridge {
    static let requestName = Notification.Name("app.ekran.Ekran.command")
    static let replyName = Notification.Name("app.ekran.Ekran.reply")
    private static var observer: NSObjectProtocol?

    static func startListening() {
        observer = DistributedNotificationCenter.default().addObserver(forName: requestName, object: nil, queue: .main) { note in
            guard let info = note.userInfo, let id = info["id"] as? String, let urlString = info["url"] as? String,
                  let url = URL(string: urlString) else { return }
            let response = CommandRouter.execute(url: url)
            let json = (try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            DistributedNotificationCenter.default().postNotificationName(replyName, object: nil, userInfo: ["id": id, "json": json], deliverImmediately: true)
        }
    }

    /// `Ekran ctl <command> key=value…` — runs in a separate short-lived process.
    static func runClient(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(CommandRouter.help)
            return 0
        }
        var components = URLComponents()
        components.scheme = "ekran"
        components.host = command
        components.queryItems = arguments.dropFirst().map { argument in
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return URLQueryItem(name: parts[0], value: parts.count > 1 ? parts[1] : "1")
        }
        guard let url = components.url else { return 2 }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "app.ekran.Ekran").isEmpty {
            FileHandle.standardError.write("Ekran не запущен\n".data(using: .utf8)!)
            return 1
        }
        let id = UUID().uuidString
        var reply: String?
        let token = DistributedNotificationCenter.default().addObserver(forName: replyName, object: nil, queue: .main) { note in
            if note.userInfo?["id"] as? String == id { reply = note.userInfo?["json"] as? String ?? "{}" }
        }
        DistributedNotificationCenter.default().postNotificationName(requestName, object: nil, userInfo: ["id": id, "url": url.absoluteString], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(5)
        while reply == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        DistributedNotificationCenter.default().removeObserver(token)
        guard let reply else {
            FileHandle.standardError.write("нет ответа от Ekran\n".data(using: .utf8)!)
            return 1
        }
        print(reply)
        return reply.contains("\"ok\" : false") ? 1 : 0
    }
}

// MARK: - Per-display scripts

enum ScriptRunner {
    static func displaysChanged(_ changes: DisplayChanges) {
        guard !changes.isInitial else { return }
        for display in changes.added where display.kind == .physical {
            run(display.settings.onConnectScript, display: display, event: "connect")
        }
        for display in changes.removed where display.kind == .physical {
            run(display.settings.onDisconnectScript, display: display, event: "disconnect")
        }
    }

    private static func run(_ script: String, display: Display, event: String) {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["EKRAN_EVENT"] = event
        environment["EKRAN_DISPLAY_ID"] = String(display.id)
        environment["EKRAN_DISPLAY_NAME"] = display.name
        environment["EKRAN_DISPLAY_KEY"] = display.key
        process.environment = environment
        do {
            try process.run()
        } catch {
            Log.automation.error("script failed: \(error.localizedDescription)")
        }
    }
}
