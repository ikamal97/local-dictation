import Foundation

/// One dictation take. While the key is held, audio is cut at natural pauses and each
/// segment is transcribed and cleaned in the background, so on release only the last
/// segment is still pending.
final class Dictation {
    private let audio: AudioCapture
    private let transcriber: Transcriber
    private let cleaner: Cleaner
    private let rules: TextRules
    private let cleanupEnabled: Bool
    private let keepAudio: Bool

    private let startIndex: Int
    /// End of the pre-roll; audio past this index was recorded during the take.
    private let liveIndex: Int
    /// Text around the cursor, filled in shortly after the take starts.
    var context = DictationContext()
    /// Length of the recorded audio, set when the take finishes.
    private(set) var audioSeconds = 0.0
    /// True when the microphone delivered nothing during the take.
    private(set) var noAudio = false
    /// The take's audio and per-segment results, kept when `keepAudio` is set.
    private(set) var takeAudio: [Float] = []
    private(set) var segments: [TakeRecord.Segment] = []
    private var committed: Int
    private var pipeline: Task<[Segment], Never>?
    private var segmentTimer: Timer?
    private var segmentCount = 0

    private let frame = 480                 // 30 ms at 16 kHz
    private let minSegmentSeconds = 4.0
    private let pauseFrames = 20            // 600 ms of quiet ends a segment
    /// Earlier segments the cleanup model sees when cleaning the next one.
    private static let contextSegments = 2

    private struct Segment {
        /// Recognized text, as the speech model returned it.
        var asr: String
        /// Recognized text with fillers removed.
        var raw: String
        /// Whether `raw` continues the previous segment's sentence.
        var continues: Bool
        /// Cleaned text.
        var text: String
        /// Sample range within the take.
        var range: Range<Int>
        var asrMs = 0
        var cleanupMs = 0
    }

    init(audio: AudioCapture, transcriber: Transcriber, cleaner: Cleaner, rules: TextRules, cleanupEnabled: Bool, keepAudio: Bool = false) {
        self.audio = audio
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.rules = rules
        self.cleanupEnabled = cleanupEnabled
        self.keepAudio = keepAudio
        startIndex = audio.beginTake()
        liveIndex = audio.currentIndex
        committed = startIndex
        segmentTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.cutAtPause()
        }
    }

    func cancel() {
        segmentTimer?.invalidate()
        pipeline?.cancel()
        audio.endTake()
    }

    /// Finishes the take and returns the final text (empty if nothing was said).
    func finish() async -> String {
        segmentTimer?.invalidate()
        let end = audio.currentIndex
        audioSeconds = Double(end - startIndex) / AudioCapture.sampleRate
        // Pre-roll alone is a stalled microphone, and the model would hallucinate on it ("Yeah.").
        if end - liveIndex < Int(0.1 * AudioCapture.sampleRate) {
            Log.info("dictation: no audio arrived from the microphone")
            audio.endTake()
            noAudio = true
            return ""
        }
        enqueue(from: committed, to: end)
        if keepAudio { takeAudio = audio.slice(from: startIndex, to: end) }
        audio.endTake()
        let parts = await pipeline?.value ?? []
        segments = parts.map {
            .init(start: $0.range.lowerBound, end: $0.range.upperBound, asr: $0.asr, text: $0.text,
                  asrMs: $0.asrMs, cleanupMs: $0.cleanupMs)
        }
        return rules.applyDictionary(parts.map(\.text).filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func loudestFrame(_ samples: [Float], frame: Int) -> Float {
        stride(from: 0, to: max(samples.count - frame + 1, 0), by: frame).map { i -> Float in
            var sum: Float = 0
            for s in samples[i..<i + frame] { sum += s * s }
            return (sum / Float(frame)).squareRoot()
        }.max() ?? 0
    }

    private func cutAtPause() {
        let now = audio.currentIndex
        let minLen = Int(minSegmentSeconds * AudioCapture.sampleRate)
        guard now - committed > minLen + pauseFrames * frame else { return }
        let window = audio.slice(from: committed, to: now)
        let energies = stride(from: 0, to: window.count - frame + 1, by: frame).map { i -> Float in
            var sum: Float = 0
            for s in window[i..<i + frame] { sum += s * s }
            return (sum / Float(frame)).squareRoot()
        }
        let sorted = energies.sorted()
        let floor = sorted[sorted.count / 10]
        let threshold = max(0.004, floor * 3)

        var run = 0
        for (i, e) in energies.enumerated() {
            run = e < threshold ? run + 1 : 0
            let frameStart = i * frame
            if run >= pauseFrames, frameStart >= minLen {
                let cut = committed + (i - run / 2) * frame
                enqueue(from: committed, to: cut)
                committed = cut
                return
            }
        }
    }

    private func enqueue(from: Int, to: Int) {
        guard to - from > Int(0.2 * AudioCapture.sampleRate) else { return }
        let samples = audio.slice(from: from, to: to)
        // Speech models hallucinate on silence ("Thank you."), so skip segments with no speech.
        let peak = Self.loudestFrame(samples, frame: frame)
        guard peak > 0.005 else {
            Log.info("segment skipped: silence (peak RMS \(String(format: "%.5f", peak)))")
            return
        }
        let previous = pipeline
        let range = (from - startIndex)..<(to - startIndex)
        let index = segmentCount
        segmentCount += 1
        let (transcriber, cleaner, cleanupEnabled) = (self.transcriber, self.cleaner, self.cleanupEnabled)
        pipeline = Task.detached(priority: .userInitiated) {
            var parts = await previous?.value ?? []
            let t0 = nowMs()
            guard let asr = try? await transcriber.transcribe(samples), !asr.isEmpty else { return parts }
            let t1 = nowMs()
            let first = !parts.contains { !$0.text.isEmpty }
            let raw = TextRules.stripFillers(asr, capitalize: first)
            // Kept with empty text so a saved take still shows what the model heard.
            guard !raw.isEmpty else {
                parts.append(Segment(asr: asr, raw: "", continues: false, text: "", range: range, asrMs: Int(t1 - t0)))
                return parts
            }
            let continues = first ? false : await MainActor.run { TextRules.continuesSentence(raw) }
            var segment = Segment(asr: asr, raw: raw, continues: continues, text: raw, range: range, asrMs: Int(t1 - t0))

            if cleanupEnabled {
                // Clean as a continuation of the last few segments, so the boundary is
                // punctuated and fillers are dropped as if the model saw the whole take.
                let earlier = parts.indices.filter { !parts[$0].text.isEmpty }.suffix(Self.contextSegments)
                let joined = TextRules.joinSegments(earlier.map { (parts[$0].raw, parts[$0].continues) } + [(raw, continues)])
                if let last = earlier.last {
                    let output = TextRules.openEnded(earlier.map { parts[$0].text }.joined(separator: " "))
                    // Joining only changes the new segment's first letter, so it keeps its length.
                    let input = String(joined.dropLast(raw.count + 1))
                    if let cleaned = cleaner.clean(String(joined.suffix(raw.count)), after: (input, output)) {
                        (parts[last].text, segment.text) = TextRules.splice(previous: parts[last].text, continuation: cleaned)
                    }
                } else if let cleaned = cleaner.clean(raw) {
                    segment.text = cleaned
                }
                segment.text = TextRules.stripFillers(segment.text, capitalize: first)
            }
            segment.cleanupMs = Int(nowMs() - t1)
            Log.info("segment \(index): \(String(format: "%.1f", Double(samples.count) / 16_000)) s audio, asr \(segment.asrMs) ms, cleanup \(segment.cleanupMs) ms")
            parts.append(segment)
            return parts
        }
    }
}
