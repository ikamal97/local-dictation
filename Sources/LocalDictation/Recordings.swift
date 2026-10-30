import Foundation

/// What was heard and produced for one take, saved next to its audio for accuracy testing.
struct TakeRecord: Codable, Equatable {
    struct Segment: Codable, Equatable {
        /// Sample range within the take's audio.
        var start: Int
        var end: Int
        /// Parakeet's text, before filler stripping.
        var asr: String
        /// Cleaned text.
        var text: String
        var asrMs: Int
        var cleanupMs: Int
    }

    var id: Int64
    var date: Date
    var sampleRate: Int
    var audioSeconds: Double
    var cleanupEnabled: Bool
    var segments: [Segment]
    /// Joined segment text with the dictionary applied.
    var finalText: String
    /// What was pasted, after fitting to the text around the cursor.
    var pastedText: String
    var appName: String?
    var latencyMs: Int

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum WAV {
    /// 16-bit PCM mono WAV.
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                        // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))  // byte rate
        append(UInt16(2)); append(UInt16(16))                       // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for s in samples { append(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}

enum Retention {
    struct Item: Equatable {
        let id: Int64
        let date: Date
        let bytes: Int
    }

    /// Items to delete: everything older than `maxAge`, then the oldest until the rest fit in `maxBytes`.
    static func expired(_ items: [Item], now: Date, maxAge: TimeInterval, maxBytes: Int) -> [Int64] {
        var doomed: [Int64] = []
        var total = 0
        for item in items.sorted(by: { $0.date > $1.date }) {
            total += item.bytes
            if now.timeIntervalSince(item.date) > maxAge || total > maxBytes { doomed.append(item.id) }
        }
        return doomed
    }
}

/// Take audio and metadata in Application Support/LocalDictation/recordings, named by history id.
/// All file work happens on a background queue.
final class RecordingStore: @unchecked Sendable {
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxBytes = 1 << 30

    let directory: URL
    private let queue = DispatchQueue(label: "recordings", qos: .utility)

    init(directory: URL = Paths.support.appendingPathComponent("recordings")) {
        self.directory = directory
    }

    func save(_ record: TakeRecord, samples: [Float]) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try WAV.encode(samples, sampleRate: record.sampleRate).write(to: url(record.id, "wav"), options: .atomic)
                try TakeRecord.encoder.encode(record).write(to: url(record.id, "json"), options: .atomic)
            } catch {
                Log.info("recordings: could not save take \(record.id): \(error)")
            }
            pruneNow()
        }
    }

    func delete(id: Int64) {
        queue.async { [self] in
            for ext in ["wav", "json"] { try? FileManager.default.removeItem(at: url(id, ext)) }
        }
    }

    func deleteAll() {
        queue.async { [self] in try? FileManager.default.removeItem(at: directory) }
    }

    func prune() {
        queue.async { [self] in pruneNow() }
    }

    /// Waits for pending file work.
    func flush() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }

    private func pruneNow() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var items: [Int64: Retention.Item] = [:]
        for file in files {
            guard let id = Int64(file.deletingPathExtension().lastPathComponent),
                  let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let date = values.contentModificationDate ?? .distantPast
            let old = items[id]
            items[id] = .init(id: id, date: min(date, old?.date ?? date), bytes: (values.fileSize ?? 0) + (old?.bytes ?? 0))
        }
        let doomed = Retention.expired(Array(items.values), now: Date(), maxAge: Self.maxAge, maxBytes: Self.maxBytes)
        for id in doomed {
            for ext in ["wav", "json"] { try? FileManager.default.removeItem(at: url(id, ext)) }
        }
        if !doomed.isEmpty { Log.info("recordings: pruned \(doomed.count) takes") }
    }

    private func url(_ id: Int64, _ ext: String) -> URL {
        directory.appendingPathComponent("\(id).\(ext)")
    }
}
