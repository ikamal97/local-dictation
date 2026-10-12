import Testing
@testable import LocalDictation

@MainActor
struct CorrectionsTests {
    typealias C = Corrections.Correction

    /// Pastes `dictated` between `before` and `after`, then diffs against `current`.
    func edits(_ before: String, _ dictated: String, _ after: String = "", current: String) -> [C]? {
        let start = before.utf16.count
        return Corrections.edits(baseline: before + dictated + after,
                                 span: start..<(start + dictated.utf16.count), current: current)
    }

    @Test func unchangedFieldHasNoEdits() {
        #expect(edits("Hi ", "talk to Kubernetis soon.", current: "Hi talk to Kubernetis soon.") == [])
    }

    @Test func findsSingleWordFix() {
        #expect(edits("", "Ask Kubernetis about the order.", current: "Ask Kubernetes about the order.")
                == [C(from: "Kubernetis", to: "Kubernetes")])
    }

    @Test func ignoresSurroundingPunctuation() {
        #expect(edits("", "I use jason, mostly.", current: "I use JSON, mostly.") == [C(from: "jason", to: "JSON")])
    }

    @Test func findsMultiWordFix() {
        #expect(edits("", "Open chat GPT now", current: "Open ChatGPT now") == [C(from: "chat GPT", to: "ChatGPT")])
    }

    @Test func findsTwoSeparateFixes() {
        #expect(edits("", "Tell Annelise to use jason today", current: "Tell Anneliese to use JSON today")
                == [C(from: "Annelise", to: "Anneliese"), C(from: "jason", to: "JSON")])
    }

    @Test func typingAfterTheDictationIsNotACorrection() {
        #expect(edits("", "Sounds good.", current: "Sounds good. See you then") == [])
    }

    @Test func changesOutsideThePasteAreRejected() {
        #expect(edits("Hello there. ", "Sounds good.", current: "Hi there. Sounds good.") == nil)
        // The message was sent and the field cleared.
        #expect(edits("", "Sounds good.", current: "") == nil)
    }

    @Test func keepsTextOnBothSidesOfThePaste() {
        #expect(edits("Notes: ", "call Wisper today", " (urgent)", current: "Notes: call Wispr today (urgent)")
                == [C(from: "Wisper", to: "Wispr")])
    }

    @Test func learnsSoundAlikesAndCasing() {
        #expect(Corrections.isLearnable(C(from: "Kubernetis", to: "Kubernetes")))
        #expect(Corrections.isLearnable(C(from: "jason", to: "JSON")))
        #expect(Corrections.isLearnable(C(from: "github", to: "GitHub")))
        #expect(Corrections.isLearnable(C(from: "chat GPT", to: "ChatGPT")))
    }

    @Test func doesNotLearnRewordingOrGrammar() {
        #expect(!Corrections.isLearnable(C(from: "great", to: "awesome")))
        #expect(!Corrections.isLearnable(C(from: "their", to: "there")))
        #expect(!Corrections.isLearnable(C(from: "then", to: "Then")))
        #expect(!Corrections.isLearnable(C(from: "a", to: "the")))
    }
}
