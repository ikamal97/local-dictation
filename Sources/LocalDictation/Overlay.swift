import AppKit
import SwiftUI

/// Floating pill near the bottom of the screen that shows what dictation is doing.
/// It never takes focus or mouse events, so the target app keeps the cursor.
@MainActor
final class Overlay {
    enum Phase: Equatable {
        case hidden
        case recording(handsFree: Bool)
        case processing
        case done(String)
        case learned(String)
        case cancelled
        case message(String)

        var isRecording: Bool { if case .recording = self { true } else { false } }
    }

    private let model = OverlayModel()
    private let panel: NSPanel
    private var levelTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var checkWork: DispatchWorkItem?
    private let levelSource: () -> Float
    /// Whether the pill should be on screen. Window alpha is mid-animation too often to say.
    private var wantsVisible = false

    init(levelSource: @escaping () -> Float) {
        self.levelSource = levelSource
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above full-screen apps' toolbar windows (level 26), which sit over .statusBar.
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        panel.alphaValue = 0

        // Space switches (entering or leaving a full-screen app) and display changes can
        // drop the panel or leave it on the wrong screen; put it back while it is in use.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.reassert(note.name.rawValue) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert("screens changed") }
        }
    }

    func show(_ phase: Phase) {
        hideWork?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { model.phase = phase }

        switch phase {
        case .hidden:
            fadeOut()
            return
        case .recording:
            startLevels()
        default:
            stopLevels()
        }
        fadeIn()

        let linger: Double? = switch phase {
        case .done: 0.7
        case .learned: 2.5
        case .cancelled: 0.8
        case .message: 4.0
        default: nil
        }
        if let linger {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
        }
    }

    private func fadeIn() {
        let appearing = !wantsVisible
        wantsVisible = true
        // Re-place on every recording start too, so a pill left on another display moves over.
        if appearing || model.phase.isRecording { position() }
        // Always re-order: the panel can be off screen even when its alpha is already 1.
        panel.orderFrontRegardless()
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        scheduleCheck()
    }

    private func fadeOut() {
        wantsVisible = false
        checkWork?.cancel()
        stopLevels()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.wantsVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func reassert(_ reason: String) {
        guard wantsVisible else { return }
        position()
        panel.orderFrontRegardless()
        panel.alphaValue = 1
        scheduleCheck(reason: reason)
    }

    /// Shortly after showing, confirm the window server actually has the pill on screen;
    /// if not, log why and show it again.
    private func scheduleCheck(reason: String = "show", retry: Bool = true) {
        checkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsVisible else { return }
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(self.panel.windowNumber))
                as? [[String: Any]])?.first
            let onScreen = info?[kCGWindowIsOnscreen as String] as? Bool ?? false
            guard !onScreen || !self.panel.isOnActiveSpace else { return }
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            Log.info("overlay: not on screen after \(reason) (cgOnscreen \(onScreen), activeSpace \(self.panel.isOnActiveSpace), frontmost \(app), frame \(self.panel.frame)); re-showing")
            self.position()
            self.panel.orderFrontRegardless()
            self.panel.alphaValue = 1
            if retry { self.scheduleCheck(reason: "retry", retry: false) }
        }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Bottom-center of the screen the user is typing on, just above the Dock.
    private func position() {
        let found = Self.frontmostWindowScreen()
        if found == nil {
            Log.info("overlay: no window found for \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"); using mouse screen")
        }
        let screen = found ?? Self.mouseScreen() ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
    }

    /// Screen holding the frontmost app's topmost window. The mouse can sit on another
    /// display (common with a full-screen app), so it is only a fallback.
    private static func frontmostWindowScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        // The list is front-to-back; take the first normal-layer window owned by the app.
        for info in windows {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 100, bounds.height >= 100
            else { continue }
            // CG window bounds are top-left based on the primary display; flip to AppKit.
            let rect = NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                              width: bounds.width, height: bounds.height)
            return NSScreen.screens.max { a, b in
                area(a.frame.intersection(rect)) < area(b.frame.intersection(rect))
            }.flatMap { area($0.frame.intersection(rect)) > 0 ? $0 : nil }
        }
        return nil
    }

    private static func mouseScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private static func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private func startLevels() {
        guard levelTimer == nil else { return }
        model.levels = Array(repeating: 0, count: OverlayModel.barCount)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let rms = max(self.levelSource(), 1e-6)
                let db = 20 * log10(rms)
                let normalized = CGFloat(min(max((db + 55) / 40, 0), 1))
                var levels = self.model.levels
                levels.removeFirst()
                levels.append(normalized)
                self.model.levels = levels
            }
        }
    }

    private func stopLevels() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 28
    @Published var phase: Overlay.Phase = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(
                Capsule()
                    .fill(.black.opacity(0.78))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording(let handsFree):
            HStack(spacing: 10) {
                PulsingDot()
                Waveform(levels: model.levels)
                if handsFree {
                    Text("fn to finish")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .transition(.opacity)
                }
            }
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                label("Transcribing")
            }
        case .done(let text):
            HStack(spacing: 6) {
                Image(systemName: "checkmark").foregroundStyle(.green)
                label(text)
            }
        case .learned(let text):
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed").foregroundStyle(.indigo)
                label(text)
            }
        case .cancelled:
            HStack(spacing: 6) {
                Image(systemName: "xmark").foregroundStyle(.white.opacity(0.6))
                label("Cancelled")
            }
        case .message(let text):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                label(text)
            }
        case .hidden:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
    }
}

private struct Waveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2.5, height: 3 + levels[i] * 19)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 1.0 / 30), value: levels)
    }
}

private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.45)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
