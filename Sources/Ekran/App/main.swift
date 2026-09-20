import AppKit

// `Ekran ctl <command> key=value…` talks to the running instance and exits.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "ctl" {
    exit(CommandBridge.runClient(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

// Two instances would fight over the same displays.
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// `kill`/`pkill` and logout scripts send SIGTERM: quit through AppKit so settings are saved and displays restored.
let terminationSources = [SIGTERM, SIGINT].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}
application.delegate = AppController.shared
application.run()
