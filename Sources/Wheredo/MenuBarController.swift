import AppKit
import Darwin

/// Menu bar status icon — shows Wheredo is running (visible in the top menu bar).
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    enum Status: String {
        case ready = "Running — press ⌘$ to speak"
        case listening = "Listening…"
        case busy = "Thinking…"
        case needAccessibility = "Needs Accessibility (⌘$ hotkey)"
        case error = "Error — click for details"
    }

    private var item: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var speakAction: (() -> Void)?
    private var pulseTimer: Timer?
    private var busyPulseTimer: Timer?
    private var pulseOn = false
    private var busyPulseOn = false
    private var currentStatus: Status = .ready

    func install(speakAction: @escaping () -> Void) {
        self.speakAction = speakAction
        guard item == nil else { return }

        item = NSStatusBar.system.statusItem(withLength: MenuBarIcon.width)
        guard let button = item?.button else { return }
        button.image = MenuBarIcon.image(for: .ready)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "Wheredo — Running"

        let menu = NSMenu()
        let header = NSMenuItem(title: "Wheredo", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusMenuItem = NSMenuItem(title: Status.ready.rawValue, action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)

        menu.addItem(.separator())

        let speak = NSMenuItem(title: "Speak now (⌘$)", action: #selector(speakNow), keyEquivalent: "")
        speak.target = self
        menu.addItem(speak)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Wheredo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item?.menu = menu
        setStatus(.ready)
    }

    func setStatus(_ status: Status) {
        currentStatus = status
        statusMenuItem?.title = status.rawValue
        item?.button?.toolTip = "Wheredo — \(status.rawValue)"
        stopPulse()
        stopBusyPulse()

        switch status {
        case .ready:
            item?.button?.image = MenuBarIcon.image(for: .ready)
        case .listening:
            item?.button?.image = MenuBarIcon.image(for: .listening)
            startPulse()
        case .busy:
            item?.button?.image = MenuBarIcon.image(for: .busy)
            startBusyPulse()
        case .needAccessibility, .error:
            item?.button?.image = MenuBarIcon.image(for: status)
        }
    }

    private func startPulse() {
        pulseOn = false
        pulseTimer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentStatus == .listening else { return }
                self.pulseOn.toggle()
                self.item?.button?.image = self.pulseOn
                    ? MenuBarIcon.listeningPulseFrame()
                    : MenuBarIcon.image(for: .listening)
            }
        }
        RunLoop.main.add(pulseTimer!, forMode: .common)
    }

    private func startBusyPulse() {
        busyPulseOn = false
        busyPulseTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentStatus == .busy else { return }
                self.busyPulseOn.toggle()
                self.item?.button?.image = self.busyPulseOn
                    ? MenuBarIcon.busyPulseFrame()
                    : MenuBarIcon.image(for: .busy)
            }
        }
        RunLoop.main.add(busyPulseTimer!, forMode: .common)
    }

    private func stopBusyPulse() {
        busyPulseTimer?.invalidate()
        busyPulseTimer = nil
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    func showAlert(title: String, message: String) {
        setStatus(.error)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func speakNow() {
        speakAction?()
    }

    @objc private func quit() {
        stopPulse()
        stopBusyPulse()
        item = nil
        NSApp.terminate(nil)
    }
}

/// User-visible feedback when stdout is not a Terminal.
enum UserFeedback {
    static var hasTerminal: Bool {
        isatty(fileno(stdout)) != 0
    }

    static var logFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Wheredo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wheredo.log")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        print(message)
        appendToFile(message)
    }

    static func error(title: String, message: String) {
        print("⚠️  \(title): \(message)")
        appendToFile("⚠️  \(title): \(message)")
        // Alert only in menu-bar mode (event loop running); a modal alert would hang one-shot CLI runs.
        if !hasTerminal && NSApp?.isRunning == true {
            Task { @MainActor in
                MenuBarController.shared.showAlert(title: title, message: message)
            }
        }
    }

    private static func appendToFile(_ message: String) {
        let line = "[\(timeFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Keep the log under ~1 MB by truncating oldest half when exceeded.
            if let size = try? handle.seekToEnd(), size > 1_000_000,
               let all = try? Data(contentsOf: url) {
                let tail = all.suffix(500_000)
                try? tail.write(to: url, options: .atomic)
                if let h2 = try? FileHandle(forWritingTo: url) {
                    _ = try? h2.seekToEnd()
                    try? h2.write(contentsOf: data)
                    try? h2.close()
                }
                return
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
