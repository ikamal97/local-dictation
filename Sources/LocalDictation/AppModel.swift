import AppKit
import ServiceManagement

/// State shared by the menu bar, the dictation pipeline and the main window.
@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Loading models…"
    @Published var isReady = false

    let history = HistoryStore()
    let dictionary = DictionaryStore()

    @Published var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var startSound: Bool { didSet { defaults.set(startSound, forKey: "startSound") } }
    @Published var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: "saveHistory") } }
    @Published var learnCorrections: Bool { didSet { defaults.set(learnCorrections, forKey: "learnCorrections") } }
    /// Empty string means the built-in microphone.
    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.info("login item: \(error)")
            }
        }
    }

    private let defaults = UserDefaults.standard

    init() {
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        startSound = defaults.object(forKey: "startSound") as? Bool ?? true
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        learnCorrections = defaults.object(forKey: "learnCorrections") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Editable copy of the personal dictionary; every change is written to disk, and
/// TextRules picks it up on the next dictation.
@MainActor
final class DictionaryStore: ObservableObject {
    struct Replacement: Identifiable, Hashable {
        let id = UUID()
        var from: String
        var to: String
    }

    @Published var replacements: [Replacement] = [] { didSet { save() } }
    @Published var vocabulary: [String] = [] { didSet { save() } }
    private var loading = false

    init() { load() }

    /// Adds a learned replacement, updating an existing one for the same phrase.
    func learn(from: String, to: String) {
        if let i = replacements.firstIndex(where: { $0.from.caseInsensitiveCompare(from) == .orderedSame }) {
            replacements[i].to = to
        } else {
            replacements.append(.init(from: from, to: to))
        }
    }

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Paths.dictionary),
              let dict = try? JSONDecoder().decode(TextRules.Dictionary.self, from: data) else { return }
        replacements = dict.replacements.map { Replacement(from: $0.from, to: $0.to) }
        vocabulary = dict.vocabulary
    }

    private func save() {
        guard !loading else { return }
        let dict = TextRules.Dictionary(
            replacements: replacements
                .filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { .init(from: $0.from.trimmingCharacters(in: .whitespaces), to: $0.to.trimmingCharacters(in: .whitespaces)) },
            vocabulary: vocabulary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(dict) {
            try? data.write(to: Paths.dictionary, options: .atomic)
        }
    }
}
