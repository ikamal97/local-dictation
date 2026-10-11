import AppKit
import CoreGraphics

/// Watches the Fn/Globe key with a listen-only event tap.
///
/// - Hold Fn: push-to-talk; recording starts on key-down.
/// - Double-tap Fn: hands-free; tap Fn again to finish.
/// - A quick single tap, or Fn used as a chord with another key, cancels.
/// - Escape cancels an active dictation.
final class Hotkey {
    enum Event { case start, handsFree, finish, cancel, permissionMissing }

    private let fnKeyCode: Int64 = 63
    private let escapeKeyCode: Int64 = 53
    /// Releases shorter than this are taps rather than push-to-talk holds.
    private let tapThreshold: Double = 0.30
    /// A second press within this window after a tap enters hands-free mode.
    private let doubleTapWindow: Double = 0.40

    private let handler: (Event) -> Void
    private var tap: CFMachPort?

    private enum State { case idle, holding(since: Double), awaitingSecondTap(Double), handsFree }
    private var state: State = .idle
    private var fnDown = false
    private var tapTimer: Timer?

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    /// Returns false when Input Monitoring permission is missing.
    @discardableResult
    func install() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                Log.info("hotkey: tap re-enabled after \(type.rawValue)")
                // Without Input Monitoring the tap is created but keeps getting disabled.
                if !CGPreflightListenEventAccess() { me.handler(.permissionMissing) }
            } else {
                me.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.info("hotkey: could not create event tap (Input Monitoring permission?)")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("hotkey: event tap installed")
        return true
    }

    /// Called by the app when a dictation ends for reasons other than Fn (e.g. error).
    func reset() {
        tapTimer?.invalidate()
        state = .idle
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        if type == .keyDown {
            if keyCode == escapeKeyCode, !isIdle {
                cancel()
            } else if case .holding(let since) = state, now - since < 1.0 {
                // Fn used as a modifier (Fn+arrow, Fn+F-key...), not a dictation.
                cancel()
            }
            return
        }

        guard type == .flagsChanged, keyCode == fnKeyCode else { return }
        let down = event.flags.contains(.maskSecondaryFn)
        guard down != fnDown else { return }
        fnDown = down

        switch (state, down) {
        case (.idle, true):
            state = .holding(since: now)
            handler(.start)
        case (.holding(let since), false):
            if now - since >= tapThreshold {
                state = .idle
                handler(.finish)
            } else {
                state = .awaitingSecondTap(now)
                tapTimer?.invalidate()
                tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    guard let self, case .awaitingSecondTap = self.state else { return }
                    self.cancel()
                }
            }
        case (.awaitingSecondTap, true):
            tapTimer?.invalidate()
            state = .handsFree
            Log.info("hotkey: hands-free mode")
            handler(.handsFree)
        case (.handsFree, true):
            state = .idle
            handler(.finish)
        default:
            break
        }
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private func cancel() {
        tapTimer?.invalidate()
        state = .idle
        handler(.cancel)
    }
}
