import AppKit
import AVFoundation
import Carbon
import ApplicationServices
import Combine
import FluidAudio

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner()
    private lazy var rules = TextRules(dictionaryURL: Paths.dictionary)
    private lazy var window = MainWindowController(model: model)
    private var hotkey: Hotkey!

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Loading models…", action: nil, keyEquivalent: "")
    private lazy var overlay = Overlay { [audio] in audio.level }
    private var warnedAboutPermission = false
    private let shortcuts = Shortcuts()
    private lazy var lastTranscript = (try? String(contentsOf: Paths.lastTranscript, encoding: .utf8)) ?? ""
    private let startSound = NSSound(named: "Tink")
    private var observers: Set<AnyCancellable> = []
    private lazy var corrections = CorrectionWatcher { [weak self] learned in self?.learn(learned) }

    private var current: Dictation?
    private var keyDownAt = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpStatusItem()
        setIcon(.idle)
        startSound?.volume = 0.3

        audio.preferredDeviceUID = model.inputDeviceUID.isEmpty ? nil : model.inputDeviceUID
        model.$inputDeviceUID.dropFirst().sink { [audio] uid in
            audio.preferredDeviceUID = uid.isEmpty ? nil : uid
        }.store(in: &observers)

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { return self.setStatus("Microphone access denied — enable it in System Settings") }
                do { try self.audio.start() } catch { self.setStatus("Microphone error: \(error.localizedDescription)") }
            }
        }

        hotkey = Hotkey { [weak self] event in self?.handle(event) }
        // Same bindings Wispr Flow uses.
        shortcuts.register(keyCode: kVK_ANSI_V, modifiers: controlKey | cmdKey) { [weak self] in self?.pasteLast() }
        shortcuts.register(keyCode: kVK_ANSI_C, modifiers: controlKey | cmdKey) { [weak self] in self?.copyLast() }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !hotkey.install() || !CGPreflightListenEventAccess() {
            setStatus("Allow Input Monitoring for LocalDictation, then relaunch")
            overlay.show(.message("Allow Input Monitoring in System Settings"))
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Log.info("app: Accessibility permission not granted yet (needed to paste)")
        }

        Task.detached(priority: .userInitiated) { [transcriber, cleaner] in
            do {
                try await transcriber.load(version: .v3)
                await MainActor.run {
                    self.model.isReady = true
                    self.setStatus("Ready — hold fn to dictate")
                }
            } catch {
                await MainActor.run { self.setStatus("Speech model failed: \(error.localizedDescription)") }
            }
            if FileManager.default.fileExists(atPath: Paths.cleanupModel.path) {
                do { try cleaner.load(path: Paths.cleanupModel) } catch { Log.info("cleanup: \(error)") }
            } else {
                Log.info("cleanup: no model at \(Paths.cleanupModel.path); using rules only")
            }
        }
    }

    /// Opening the app again from Spotlight or the Dock shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    // MARK: - Dictation flow

    private func handle(_ event: Hotkey.Event) {
        switch event {
        case .start:
            guard model.isReady, current == nil else { return }
            keyDownAt = nowMs()
            corrections.stop()
            let dictation = Dictation(audio: audio, transcriber: transcriber, cleaner: cleaner, rules: rules, cleanupEnabled: model.cleanupEnabled)
            current = dictation
            rules.reloadIfChanged()
            DispatchQueue.global(qos: .userInitiated).async {
                let ctx = ContextCapture.capture()
                DispatchQueue.main.async { dictation.context = ctx }
            }
            Log.info("dictation: start (key-down to recording \(String(format: "%.1f", nowMs() - keyDownAt)) ms)")
            overlay.show(.recording(handsFree: false))
            setIcon(.recording)
            if model.startSound {
                startSound?.stop()
                startSound?.play()
            }
        case .handsFree:
            guard current != nil else { return }
            overlay.show(.recording(handsFree: true))
        case .permissionMissing:
            guard !warnedAboutPermission else { return }
            warnedAboutPermission = true
            setStatus("Allow Input Monitoring for LocalDictation, then relaunch")
            overlay.show(.message("Allow Input Monitoring in System Settings"))
        case .cancel:
            guard let dictation = current else { return }
            dictation.cancel()
            current = nil
            overlay.show(.cancelled)
            setIcon(.idle)
            Log.info("dictation: cancelled")
        case .finish:
            guard let dictation = current else { return }
            current = nil
            setIcon(.processing)
            overlay.show(.processing)
            let releasedAt = nowMs()
            Task { @MainActor in
                let transcript = await dictation.finish()
                let text = self.rules.fit(transcript, to: dictation.context)
                let latency = Int(nowMs() - releasedAt)
                if dictation.noAudio {
                    self.overlay.show(.message("No audio from the microphone"))
                } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.overlay.show(.message("Didn't catch that"))
                } else {
                    Inserter.insert(text)
                    self.overlay.show(.done("Inserted"))
                    if self.model.learnCorrections { self.corrections.watch(text) }
                    self.remember(transcript)
                    if self.model.saveHistory {
                        self.model.history.add(
                            text: transcript, appName: HistoryStore.appName(forBundleID: dictation.context.bundleID),
                            audioSeconds: dictation.audioSeconds, latencyMs: latency)
                    }
                }
                self.setIcon(.idle)
                Log.info("dictation: done, release to paste \(latency) ms, \(text.split(separator: " ").count) words")
            }
        }
    }

    // MARK: - Learning from corrections

    private func learn(_ learned: [Corrections.Correction]) {
        for c in learned {
            model.dictionary.learn(from: c.from, to: c.to)
            Log.info("dictionary: learned \"\(c.from)\" → \"\(c.to)\"")
        }
        let names = learned.map { "“\($0.to)”" }.joined(separator: ", ")
        overlay.show(.learned("Added \(names) to dictionary"))
    }

    // MARK: - Last transcript

    private func remember(_ transcript: String) {
        lastTranscript = transcript
        try? Data(transcript.utf8).write(to: Paths.lastTranscript, options: .atomic)
    }

    @objc private func pasteLast() {
        guard !lastTranscript.isEmpty else { return overlay.show(.message("No transcript yet")) }
        let transcript = lastTranscript
        corrections.stop()
        DispatchQueue.global(qos: .userInitiated).async {
            // The shortcut fires on key-down, with ⌃⌘ still held. A ⌘V posted now reaches the app
            // as ⌃⌘V, which isn't Paste, so wait (up to 2 s) for the modifiers to come up.
            let held: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
            let deadline = Date().addingTimeInterval(2)
            while !CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty, Date() < deadline {
                usleep(10_000)
            }
            let ctx = ContextCapture.capture()
            DispatchQueue.main.async {
                Inserter.insert(self.rules.fit(transcript, to: ctx))
                self.overlay.show(.done("Pasted last transcript"))
                Log.info("paste-last: pasted \(transcript.split(separator: " ").count) words")
            }
        }
    }

    @objc private func copyLast() {
        guard !lastTranscript.isEmpty else { return overlay.show(.message("No transcript yet")) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        overlay.show(.done("Copied last transcript"))
    }

    // MARK: - Menus

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Open Local Dictation", #selector(openWindow), key: ""))
        menu.addItem(item("History", #selector(openHistory), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Paste Last Transcript", #selector(pasteLast), key: "v", modifiers: [.control, .command]))
        menu.addItem(item("Copy Last Transcript", #selector(copyLast), key: "c", modifiers: [.control, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem(title: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Standard app and Edit menus, so copy/paste/select-all work in the window's text fields.
    private func setUpMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Local Dictation", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(appMenu, title: "Local Dictation"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu(edit, title: "Edit"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        main.addItem(submenu(windowMenu, title: "Window"))

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func openWindow() { window.show(.home) }
    @objc private func openHistory() { window.show(.history) }
    @objc private func openSettings() { window.show(.settings) }

    private func setIcon(_ state: MenuBarIcon.State) {
        statusItem.button?.image = MenuBarIcon.image(state)
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
        model.status = text
        Log.info("status: \(text)")
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
