import Foundation
import Testing
@testable import LocalDictation

struct RecordingsTests {
    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func int16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
    }

    @Test func wavHeaderDescribes16kMonoPCM() {
        let data = WAV.encode([0, 0.5, -1, 2], sampleRate: 16_000)
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(uint32(data, 4) == UInt32(data.count - 8))
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(uint32(data, 24) == 16_000)
        #expect(uint32(data, 28) == 32_000)
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(uint32(data, 40) == 8)
        #expect([44, 46, 48, 50].map { int16(data, $0) } == [0, 16_383, -32_767, 32_767])
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func item(_ id: Int64, daysAgo: Double, bytes: Int = 10) -> Retention.Item {
        .init(id: id, date: now.addingTimeInterval(-daysAgo * 86_400), bytes: bytes)
    }

    @Test func retentionDropsOldTakes() {
        let items = [item(1, daysAgo: 40), item(2, daysAgo: 29), item(3, daysAgo: 31)]
        #expect(Set(Retention.expired(items, now: now, maxAge: 30 * 86_400, maxBytes: 1_000)) == [1, 3])
    }

    @Test func retentionDropsOldestFirstOverSizeCap() {
        let items = [item(1, daysAgo: 3, bytes: 40), item(2, daysAgo: 1, bytes: 40), item(3, daysAgo: 2, bytes: 40)]
        #expect(Retention.expired(items, now: now, maxAge: 30 * 86_400, maxBytes: 100) == [1])
        #expect(Retention.expired(items, now: now, maxAge: 30 * 86_400, maxBytes: 120) == [])
    }

    @Test func recordEncodesSnakeCaseAndRoundTrips() throws {
        let record = TakeRecord(
            id: 7, date: now, sampleRate: 16_000, audioSeconds: 2.5, cleanupEnabled: true,
            segments: [.init(start: 0, end: 40_000, asr: "um send the report", text: "Send the report.", asrMs: 80, cleanupMs: 120)],
            finalText: "Send the report.", pastedText: "Send the report. ", appName: nil, latencyMs: 210)
        let data = try TakeRecord.encoder.encode(record)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["final_text"] as? String == "Send the report.")
        #expect(json["sample_rate"] as? Int == 16_000)
        let segment = try #require((json["segments"] as? [[String: Any]])?.first)
        #expect(segment["asr"] as? String == "um send the report")
        #expect(segment["end"] as? Int == 40_000)
        #expect(try TakeRecord.decoder.decode(TakeRecord.self, from: data) == record)
    }

    @Test func storeDeletesTakeFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)
        let record = TakeRecord(id: 3, date: now, sampleRate: 16_000, audioSeconds: 0, cleanupEnabled: false,
                                segments: [], finalText: "", pastedText: "", appName: nil, latencyMs: 0)
        store.save(record, samples: [0, 0.1])
        store.save(TakeRecord(id: 4, date: now, sampleRate: 16_000, audioSeconds: 0, cleanupEnabled: false,
                              segments: [], finalText: "", pastedText: "", appName: nil, latencyMs: 0), samples: [0])
        store.delete(id: 3)
        await store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["4.json", "4.wav"])
    }
}
