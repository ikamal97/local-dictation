import Foundation

enum Paths {
    static let support: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalDictation")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// GGUF cleanup model (fine-tuned LFM2.5 1.2B).
    static let cleanupModel = support.appendingPathComponent("models/cleanup.gguf")

    /// Personal dictionary: {"replacements": [{"from", "to"}], "vocabulary": [names]}.
    static let dictionary = support.appendingPathComponent("dictionary.json")

    /// The most recent transcript, before it was fitted to the cursor.
    static let lastTranscript = support.appendingPathComponent("last-transcript.txt")
}
