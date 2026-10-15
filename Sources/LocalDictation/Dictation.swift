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

    private let startIndex: Int
    /// End of the pre-roll; audio past this index was recorded during the take.
    private let liveIndex: Int
    /// Text around the cursor, filled in shortly after the take starts.
    var context = DictationContext()
    /// Length of the recorded audio, set when the take finishes.
    private(set) var audioSeconds = 0.0
    /// True when the microphone delivered nothing during the take.
    private(set) var noAudio = false
    private var committed: Int
    private var pipeline: Task<[String], Never>?
    private var segmentTimer: Timer?
    private var segmentCount = 0

    private let frame = 480                 // 30 ms at 16 kHz
    private let minSegmentSeconds = 4.0
    private let pauseFrames = 20            // 600 ms of quiet ends a segment

    init(audio: AudioCapture, transcriber: Transcriber, cleaner: Cleaner, rules: TextRules, cleanupEnabled: Bool) {
        self.audio = audio
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.rules = rules
        self.cleanupEnabled = cleanupEnabled
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
        audio.endTake()
        let parts = await pipeline?.value ?? []
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
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
        guard Self.loudestFrame(samples, frame: frame) > 0.005 else {
            Log.info("segment skipped: silence")
            return
        }
        let previous = pipeline
        let index = segmentCount
        segmentCount += 1
        let (transcriber, cleaner, rules, cleanupEnabled) = (self.transcriber, self.cleaner, self.rules, self.cleanupEnabled)
        pipeline = Task.detached(priority: .userInitiated) {
            var parts = await previous?.value ?? []
            let t0 = nowMs()
            guard let raw = try? await transcriber.transcribe(samples), !raw.isEmpty else { return parts }
            let t1 = nowMs()
            let stripped = TextRules.stripFillers(raw)
            var text = stripped
            if cleanupEnabled, !stripped.isEmpty, let cleaned = cleaner.clean(raw) {
                text = cleaned
            }
            text = rules.applyDictionary(text)
            Log.info("segment \(index): \(String(format: "%.1f", Double(samples.count) / 16_000)) s audio, asr \(Int(t1 - t0)) ms, cleanup \(Int(nowMs() - t1)) ms")
            parts.append(text)
            return parts
        }
    }
}
