import FluidAudio
import Foundation

/// Parakeet TDT on the Apple Neural Engine via FluidAudio. Loaded once and kept warm.
actor Transcriber {
    private var manager: AsrManager?
    private var decoderLayers = 2

    func load(version: AsrModelVersion) async throws {
        let t0 = nowMs()
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        decoderLayers = await manager.decoderLayerCount
        self.manager = manager
        // Warm-up so the first real dictation doesn't pay for graph setup.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
        Log.info("asr: \(version) loaded and warmed in \(Int(nowMs() - t0)) ms")
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw NSError(domain: "Transcriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "ASR not loaded"]) }
        // Parakeet needs at least ~1 s of audio; pad short clips with silence.
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
