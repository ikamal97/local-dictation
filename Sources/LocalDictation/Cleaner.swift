import Foundation
import llama

/// Rewrites raw transcripts with the fine-tuned cleanup model (llama.cpp, Metal).
/// All calls are serialized on one queue; the model stays loaded.
final class Cleaner {
    private let queue = DispatchQueue(label: "cleaner", qos: .userInitiated)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    var isLoaded: Bool { queue.sync { context != nil } }

    func load(path: URL) throws {
        try queue.sync {
            let t0 = nowMs()
            llama_backend_init()
            var mparams = llama_model_default_params()
            mparams.n_gpu_layers = 99
            guard let model = llama_model_load_from_file(path.path, mparams) else {
                throw NSError(domain: "Cleaner", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not load \(path.path)"])
            }
            var cparams = llama_context_default_params()
            cparams.n_ctx = 4096
            cparams.n_batch = 2048
            guard let context = llama_init_from_model(model, cparams) else {
                throw NSError(domain: "Cleaner", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not create context"])
            }
            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            self.model = model
            self.context = context
            self.vocab = llama_model_get_vocab(model)
            self.sampler = sampler
            _ = generate("Okay um so this is a warm up.", newWords: 8)
            Log.info("cleanup: model loaded and warmed in \(Int(nowMs() - t0)) ms")
        }
    }

    /// Returns cleaned text, or nil if the model is unavailable or produced something implausible.
    ///
    /// `context` is the raw text and cleaned output of the take's earlier segments. The model
    /// sees them as a dictation it is partway through cleaning and only writes the rest, so it
    /// punctuates the boundary and drops fillers as if it had the whole take. The result may
    /// then start with punctuation that ends the earlier output (see `TextRules.splice`).
    func clean(_ raw: String, after context: (raw: String, output: String)? = nil) -> String? {
        queue.sync {
            guard self.context != nil else { return nil }
            let out = context.map { generate("\($0.raw) \(raw)", continuing: $0.output, newWords: raw.split(separator: " ").count) }
                ?? generate(raw, newWords: raw.split(separator: " ").count)
            let inWords = raw.split(separator: " ").count
            let outWords = out.split(separator: " ").count
            // Guard against dropped or invented content.
            if out.isEmpty || (inWords >= 6 && (Double(outWords) < Double(inWords) * 0.6 || Double(outWords) > Double(inWords) * 1.4)) {
                Log.info("cleanup: rejected output (\(inWords) -> \(outWords) words)")
                return nil
            }
            return out
        }
    }

    private func generate(_ raw: String, continuing prefix: String = "", newWords: Int) -> String {
        guard let context, let vocab, let sampler else { return "" }
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        let prompt = "### Input:\n\(raw)\n\n### Output:\n\(prefix)"
        var tokens = tokenize(prompt)
        let maxNew = Int(Double(newWords) * 2.5) + 32
        var output = ""
        var pieceBytes: [UInt8] = []

        let status = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard status == 0 else { return "" }

        for _ in 0..<maxNew {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            pieceBytes += piece(token)
            if let text = String(bytes: pieceBytes, encoding: .utf8) {
                output += text
                pieceBytes.removeAll()
            }
            if let range = output.range(of: "###") {
                output = String(output[..<range.lowerBound])
                break
            }
            if llama_decode(context, llama_batch_get_one(&token, 1)) != 0 { break }
        }
        if !prefix.isEmpty {
            output = output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        let n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }
}
