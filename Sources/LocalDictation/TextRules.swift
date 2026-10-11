import AppKit

/// Deterministic text fixes applied around the cleanup model: filler removal, the personal
/// dictionary, name spelling from context, and spacing/capitalization to fit the cursor.
///
/// The dictionary file looks like:
///   { "replacements": [{"from": "jason", "to": "JSON"}], "vocabulary": ["Aaliyah"] }
/// It is re-read whenever it changes on disk.
final class TextRules {
    struct Dictionary: Codable {
        struct Replacement: Codable { let from: String; let to: String }
        var replacements: [Replacement] = []
        var vocabulary: [String] = []
    }

    private let url: URL
    private var loadedAt: Date?
    private var replacements: [(NSRegularExpression, String)] = []
    private var vocabulary: [String] = []

    private static let fillers = try! NSRegularExpression(
        pattern: #"\b(?:um+|uh+|erm|uhm|hmm+|mm+)\b[,.]?\s*"#, options: [.caseInsensitive])

    init(dictionaryURL: URL) {
        url = dictionaryURL
        reloadIfChanged()
    }

    // MARK: - Dictionary

    func reloadIfChanged() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard modified != loadedAt else { return }
        loadedAt = modified
        guard let data = try? Data(contentsOf: url) else { return }
        guard let dict = try? JSONDecoder().decode(Dictionary.self, from: data) else {
            Log.info("rules: could not parse \(url.lastPathComponent); keeping previous dictionary")
            return
        }
        replacements = dict.replacements.compactMap { r in
            guard !r.from.isEmpty, r.from != r.to else { return nil }
            let pattern = #"(?<![\w])"# + NSRegularExpression.escapedPattern(for: r.from) + #"(?![\w])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: r.to))
        }
        vocabulary = dict.vocabulary.filter { !$0.isEmpty }
        Log.info("rules: dictionary loaded (\(replacements.count) replacements, \(vocabulary.count) vocabulary words)")
    }

    func applyDictionary(_ text: String) -> String {
        replacements.reduce(text) { acc, pair in
            pair.0.stringByReplacingMatches(in: acc, range: NSRange(acc.startIndex..., in: acc), withTemplate: pair.1)
        }
    }

    // MARK: - Fillers

    /// Removes filler words; used before the model and as the fallback when it is unavailable.
    static func stripFillers(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = fillers.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespaces)
        if let first = out.first, first.isLowercase { out = first.uppercased() + out.dropFirst() }
        return out
    }

    // MARK: - Context

    /// Fixes name spellings using vocabulary and names visible near the cursor, then adjusts
    /// spacing, capitalization and final punctuation to fit where the text is inserted.
    /// Call on the main thread (uses NSSpellChecker).
    func fit(_ text: String, to ctx: DictationContext) -> String {
        var out = correctNames(text, candidates: vocabulary + Self.names(in: ctx))
        guard !out.isEmpty else { return out }

        let before = ctx.before
        let after = ctx.after
        let lastBefore = before.last(where: { !$0.isWhitespace })
        let midSentence = lastBefore.map { !".!?:\n".contains($0) } ?? false

        // Continuing a sentence: lowercase the first word unless it is a name, "I", or an acronym.
        if midSentence, let firstWord = out.split(separator: " ").first.map(String.init),
           Self.isCommonWord(firstWord), !firstWord.hasPrefix("I'"), firstWord != "I",
           firstWord.dropFirst().allSatisfy({ !$0.isUppercase }) {
            out = out.prefix(1).lowercased() + out.dropFirst()
        }

        // Inserting before more text on the same line: no closing period.
        if let next = after.first, !next.isNewline, out.hasSuffix(".") {
            out.removeLast()
        }

        // Spacing on both sides.
        if let last = before.last, !last.isWhitespace, !"([{\"'“‘/".contains(last) {
            out = " " + out
        }
        if let next = after.first, !next.isWhitespace, !".,;:!?)]}\"'”’".contains(next) {
            out += " "
        }
        return out
    }

    private static func names(in ctx: DictationContext) -> [String] {
        let text = ctx.windowTitle + " " + ctx.before + " " + ctx.after
        var seen = Set<String>()
        return text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).compactMap { token in
            let word = String(token)
            guard word.count >= 4, word.first?.isUppercase == true, !isCommonWord(word),
                  seen.insert(word).inserted else { return nil }
            return word
        }
    }

    private func correctNames(_ text: String, candidates: [String]) -> String {
        guard !candidates.isEmpty else { return text }
        let keyed = candidates.map { ($0, Self.soundex($0)) }
        var words = text.components(separatedBy: " ")
        for (i, raw) in words.enumerated() {
            let core = raw.trimmingCharacters(in: .punctuationCharacters)
            // Capitalized words may be misheard names even if the spell checker knows them
            // ("Aliyah" for "Aaliyah"); lowercase dictionary words are never touched.
            guard core.count >= 4, core.first?.isUppercase == true || !Self.isCommonWord(core),
                  !candidates.contains(where: { $0.caseInsensitiveCompare(core) == .orderedSame }) else { continue }
            let key = Self.soundex(core)
            let match = keyed
                .filter { $0.1 == key && $0.0.first?.lowercased() == core.first?.lowercased() }
                .min { Self.distance($0.0.lowercased(), core.lowercased()) < Self.distance($1.0.lowercased(), core.lowercased()) }
            if let (name, _) = match, Self.distance(name.lowercased(), core.lowercased()) <= max(2, core.count / 3) {
                words[i] = raw.replacingOccurrences(of: core, with: name)
            }
        }
        return words.joined(separator: " ")
    }

    // MARK: - Helpers

    private static func isCommonWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        return NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0).location == NSNotFound
    }

    private static func soundex(_ word: String) -> String {
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let letters = word.lowercased().filter(\.isLetter)
        guard let first = letters.first else { return "" }
        var out = String(first).uppercased()
        var last = codes[first]
        for c in letters.dropFirst() {
            let code = codes[c]
            if let code, code != last { out.append(code) }
            if c != "h" && c != "w" { last = code }
            if out.count == 4 { break }
        }
        return out.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let temp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = temp
            }
        }
        return row[b.count]
    }
}
