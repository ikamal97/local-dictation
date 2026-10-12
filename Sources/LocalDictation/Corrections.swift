import AppKit
@preconcurrency import ApplicationServices

/// Learns dictionary replacements from the user's own fixes. After a paste, the same text
/// field is re-read for a short while; if a dictated word is swapped for one that looks or
/// sounds like it ("Kubernetis" → "Kubernetes"), that swap is added to the dictionary.
enum Corrections {
    struct Correction: Equatable {
        let from: String
        let to: String
    }

    /// Word swaps between `baseline` and `current`, provided every change falls inside
    /// `span` (UTF-16 offsets of the pasted text in `baseline`). Returns nil when something
    /// outside the span changed, e.g. the message was sent and the field cleared.
    static func edits(baseline: String, span: Range<Int>, current: String) -> [Correction]? {
        let old = Array(baseline.utf16), new = Array(current.utf16)
        guard old != new else { return [] }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        // Widen the changed region to whole words; the widening is shared text, so both
        // sides move together.
        var start = prefix, oldEnd = old.count - suffix, newEnd = new.count - suffix
        while start > 0, !isSpace(old[start - 1]) { start -= 1 }
        while oldEnd < old.count, !isSpace(old[oldEnd]) { oldEnd += 1; newEnd += 1 }
        guard start >= span.lowerBound, oldEnd <= span.upperBound else { return nil }

        let oldWords = words(old[start..<oldEnd]), newWords = words(new[start..<newEnd])
        // All of the dictation is gone, e.g. a message box emptied by sending.
        if newWords.isEmpty, oldWords.count == words(old[span]).count { return nil }
        return substitutions(oldWords, newWords).compactMap { o, n in
            let from = o.map(trimPunctuation).joined(separator: " ")
            let to = n.map(trimPunctuation).joined(separator: " ")
            return (1...3).contains(o.count) && (1...3).contains(n.count) && !from.isEmpty && !to.isEmpty && from != to
                ? Correction(from: from, to: to) : nil
        }
    }

    /// Whether a swap looks like fixing a mishearing rather than rewording. Main thread only
    /// (uses NSSpellChecker).
    static func isLearnable(_ c: Correction) -> Bool {
        let a = c.from.lowercased().filter { $0.isLetter || $0.isNumber }
        let b = c.to.lowercased().filter { $0.isLetter || $0.isNumber }
        guard a.count >= 2, b.count >= 2, c.to.count <= 40 else { return false }

        if a == b {
            // Only casing changed: learn "github" → "GitHub", not a capitalized sentence start.
            return c.from.dropFirst() != c.to.dropFirst()
        }
        let similar = TextRules.distance(a, b) <= max(1, max(a.count, b.count) * 2 / 5)
            || TextRules.soundex(a) == TextRules.soundex(b)
        guard similar else { return false }
        // Swapping one ordinary word for another ("their" → "there") is grammar, not a
        // mishearing; replacing it everywhere would do harm.
        let ordinary = { (s: String) in s.split(separator: " ").allSatisfy { TextRules.isCommonWord(String($0)) && $0.dropFirst().allSatisfy(\.isLowercase) } }
        return !(ordinary(c.from) && ordinary(c.to))
    }

    // MARK: - Helpers

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0
    }

    private static func words(_ units: ArraySlice<UInt16>) -> [String] {
        String(decoding: units, as: UTF16.self).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func trimPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// Runs of words that differ between `a` and `b`, aligned on their longest common subsequence.
    private static func substitutions(_ a: [String], _ b: [String]) -> [([String], [String])] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var runs: [([String], [String])] = []
        var i = 0, j = 0, runA: [String] = [], runB: [String] = []
        func flush() {
            if !runA.isEmpty || !runB.isEmpty { runs.append((runA, runB)) }
            runA = []; runB = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                runB.append(b[j]); j += 1
            } else {
                runA.append(a[i]); i += 1
            }
        }
        flush()
        return runs
    }
}

/// Watches the field a dictation was just pasted into and reports learnable corrections
/// once the user moves on: after 30 seconds, when the field changes outside the pasted
/// text (sent, cleared, switched), or when the next dictation starts.
@MainActor
final class CorrectionWatcher {
    private let onLearn: ([Corrections.Correction]) -> Void
    private var session = 0
    private var timer: Timer?
    private var element: AXUIElement?
    private var baseline = ""
    private var span = 0..<0
    private var lastValue: String?
    /// Latest field contents seen twice in a row, so a half-typed word isn't learned.
    private var settled: String?
    private var deadline = Date()

    init(onLearn: @escaping ([Corrections.Correction]) -> Void) {
        self.onLearn = onLearn
    }

    /// Call right after pasting `text`.
    func watch(_ text: String) {
        stop()
        session += 1
        let id = session
        let length = (text as NSString).length
        // Give the target app a moment to apply the paste before taking the baseline.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            guard let (element, value, cursor) = Self.focusedField() else { return }
            let ns = value as NSString
            var start = cursor - length
            if start < 0 || cursor > ns.length || ns.substring(with: NSRange(location: start, length: length)) != text {
                let found = ns.range(of: text, options: .backwards)
                guard found.location != NSNotFound else { return }
                start = found.location
            }
            DispatchQueue.main.async {
                guard id == self.session else { return }
                self.element = element
                self.baseline = value
                self.span = start..<(start + length)
                self.lastValue = value
                self.settled = value
                self.deadline = Date().addingTimeInterval(30)
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
            }
        }
    }

    /// Stops watching and learns from whatever the user had settled on.
    func stop() {
        timer?.invalidate()
        timer = nil
        defer { element = nil; settled = nil; lastValue = nil }
        guard element != nil, let settled,
              let edits = Corrections.edits(baseline: baseline, span: span, current: settled) else { return }
        let learned = edits.filter(Corrections.isLearnable)
        if !learned.isEmpty { onLearn(learned) }
    }

    private func poll() {
        guard let element, Date() < deadline else { return stop() }
        let id = session
        DispatchQueue.global(qos: .utility).async {
            let value = Self.value(of: element)
            DispatchQueue.main.async {
                guard id == self.session, self.element != nil else { return }
                guard let value, Corrections.edits(baseline: self.baseline, span: self.span, current: value) != nil else {
                    return self.stop()
                }
                if value == self.lastValue { self.settled = value }
                self.lastValue = value
            }
        }
    }

    // MARK: - Accessibility

    private nonisolated static func focusedField() -> (AXUIElement, String, Int)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let value = Self.value(of: element) else { return nil }
        var rangeValue: AnyObject?
        var range = CFRange(location: (value as NSString).length, length: 0)
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        }
        return (element, value, range.location)
    }

    private nonisolated static func value(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
