import AppKit
import Carbon
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case home = "Home", history = "History", dictionary = "Dictionary", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private let selection = SelectionModel()

    init(model: AppModel) { self.model = model }

    /// Show a Dock icon while the window is open; menu bar only otherwise.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func show(_ section: Section? = nil) {
        if let section { selection.section = section }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Local Dictation"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 480)
            window.contentViewController = NSHostingController(rootView: MainView(model: model, selection: selection))
            window.center()
            window.setFrameAutosaveName("MainWindow")
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SelectionModel: ObservableObject {
    @Published var section: Section = .home
}

// MARK: - Root

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var selection: SelectionModel

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { selection.section }, set: { selection.section = $0 ?? .home })) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) { StatusFooter(model: model) }
        } detail: {
            switch selection.section {
            case .home: HomeView(model: model, history: model.history, selection: selection)
            case .history: HistoryView(history: model.history)
            case .dictionary: DictionaryView(store: model.dictionary)
            case .settings: SettingsView(model: model)
            }
        }
        .tint(.indigo)
    }
}

private struct StatusFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.isReady ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(model.isReady ? "Ready" : "Loading…").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }
}

// MARK: - Home

private struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryStore
    @ObservedObject var selection: SelectionModel

    private var local: [HistoryEntry] { history.entries.filter { $0.source == .local } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                stats
                recent
                shortcuts
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Dictation").font(.system(size: 24, weight: .semibold))
                Text(model.status).foregroundStyle(.secondary)
            }
        }
    }

    private var stats: some View {
        let words = local.reduce(0) { $0 + $1.words }
        let latencies = local.compactMap(\.latencyMs).sorted()
        let median = latencies.isEmpty ? nil : latencies[latencies.count / 2]
        let speaking = local.reduce(0) { $0 + $1.audioSeconds }
        let typingMinutes = Double(words) / 40
        let saved = max(0, typingMinutes - speaking / 60)
        let since = local.last?.date ?? Date()
        let months = max(1, Int(ceil(Date().timeIntervalSince(since) / (30 * 86_400))))

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            StatCard(title: "Words dictated", value: words.formatted(), detail: "\(local.count.formatted()) dictations")
            StatCard(title: "Release to paste", value: median.map { "\($0) ms" } ?? "—", detail: "median")
            StatCard(title: "Time saved", value: "\(Int(saved.rounded())) min", detail: "vs. typing")
            StatCard(title: "Saved on Wispr", value: "$\(months * 15)", detail: "at $15/month")
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                Button("See all") { selection.section = .history }.buttonStyle(.link)
            }
            if history.entries.isEmpty {
                Text("Hold fn anywhere and start talking. Your dictations will show up here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(history.entries.prefix(5)) { entry in
                        HistoryRow(entry: entry, history: history)
                        if entry != history.entries.prefix(5).last { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts").font(.headline)
            ShortcutGrid()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ShortcutGrid: View {
    private let rows: [(String, String)] = [
        ("fn", "Hold to dictate, release to insert"),
        ("fn fn", "Double-tap for hands-free; tap fn to finish"),
        ("esc", "Cancel the current dictation"),
        ("⌃⌘V", "Paste last transcript"),
        ("⌃⌘C", "Copy last transcript"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            ForEach(rows, id: \.0) { key, action in
                GridRow {
                    Text(key)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    Text(action).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        query.isEmpty ? history.entries
            : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.appName?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    private var days: [(Date, [HistoryEntry])] {
        let groups = Dictionary(grouping: filtered.prefix(3000)) { Calendar.current.startOfDay(for: $0.date) }
        return groups.sorted { $0.key > $1.key }
    }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                       description: Text("Hold fn anywhere to dictate. You can also import your Wispr Flow history in Settings."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(days, id: \.0) { day, entries in
                        SwiftUI.Section(day.formatted(.dateTime.weekday(.wide).month().day().year())) {
                            ForEach(entries) { HistoryRow(entry: $0, history: history) }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search dictations")
        .navigationTitle("History")
        .toolbar {
            Button(role: .destructive) { confirmClear = true } label: { Label("Clear History", systemImage: "trash") }
                .disabled(history.entries.isEmpty)
        }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This removes every saved dictation from this Mac, including anything imported from Wispr Flow.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let history: HistoryStore
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).lineLimit(4).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                    if let app = entry.appName { Text("·"); Text(app) }
                    Text("·"); Text("\(entry.words) words")
                    if entry.source == .wispr { Text("·"); Text("Wispr Flow") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .help("Copy")
                Button { history.delete(entry) } label: { Image(systemName: "trash") }
                    .help("Delete")
            }
            .buttonStyle(.borderless)
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Dictionary

private struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore
    @State private var newWord = ""

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach($store.replacements) { $item in
                    HStack {
                        TextField("When I say", text: $item.from).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Write", text: $item.to).textFieldStyle(.roundedBorder)
                        Button { store.replacements.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button { store.replacements.append(.init(from: "", to: "")) } label: {
                    Label("Add replacement", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Replacements")
            } footer: {
                Text("Swap a word or phrase every time it's transcribed, e.g. a name the model mishears. Words you fix right after dictating are added here automatically.")
            }

            SwiftUI.Section {
                if !store.vocabulary.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(store.vocabulary, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word)
                                Button { store.vocabulary.removeAll { $0 == word } } label: {
                                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.indigo.opacity(0.15), in: Capsule())
                        }
                    }
                }
                HStack {
                    TextField("Add a name or term", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWord)
                    Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names and terms to spell correctly. Close mishearings (\"Aliyah\" for \"Aaliyah\") are fixed automatically.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictionary")
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !store.vocabulary.contains(word) else { return }
        store.vocabulary.append(word)
        newWord = ""
    }
}

/// Wraps children onto multiple lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = ([], 0, 0)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var devices = AudioCapture.inputDevices()
    @State private var importResult: String?
    @State private var importing = false

    private var selectedIsBluetooth: Bool {
        devices.first { $0.uid == model.inputDeviceUID }?.isBluetooth ?? false
    }

    var body: some View {
        Form {
            SwiftUI.Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Play a sound when recording starts", isOn: $model.startSound)
                Toggle(isOn: $model.cleanupEnabled) {
                    Text("AI cleanup")
                    Text("Removes filler words, fixes punctuation and handles self-corrections, on this Mac.")
                }
                Toggle(isOn: $model.learnCorrections) {
                    Text("Learn from my corrections")
                    Text("When you fix a misheard word right after dictating, it's added to your dictionary.")
                }
            }

            SwiftUI.Section {
                Picker("Microphone", selection: $model.inputDeviceUID) {
                    Text("Built-in microphone (recommended)").tag("")
                    ForEach(devices.filter { !$0.isBuiltIn }) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .onAppear { devices = AudioCapture.inputDevices() }
            } header: {
                Text("Audio")
            } footer: {
                if selectedIsBluetooth {
                    Label("Bluetooth mics stay open while the app runs, which keeps headphones like AirPods in lower-quality call mode.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("The mic stays open so dictation starts instantly. Audio is only processed while you hold fn and never leaves this Mac.")
                }
            }

            SwiftUI.Section("Shortcuts") {
                ShortcutGrid()
            }

            SwiftUI.Section {
                Toggle("Save dictation history", isOn: $model.saveHistory)
                Toggle(isOn: $model.saveAudio) {
                    Text("Save audio for accuracy testing")
                    Text("Keeps each dictation's recording and raw transcript on this Mac for 30 days (up to 1 GB).")
                }
                .disabled(!model.saveHistory)
                HStack {
                    Button(importing ? "Importing…" : (model.history.hasWisprImport ? "Re-import from Wispr Flow" : "Import from Wispr Flow")) {
                        importing = true
                        let count = model.history.importFromWispr()
                        importing = false
                        importResult = count > 0 ? "Imported \(count.formatted()) dictations." : "Nothing found to import."
                    }
                    .disabled(importing)
                    if let importResult { Text(importResult).foregroundStyle(.secondary) }
                }
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.support])
                }
            } header: {
                Text("Data")
            } footer: {
                Text("History, your dictionary and the models are stored in ~/Library/Application Support/LocalDictation. Wispr Flow's data is only read, never changed.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
