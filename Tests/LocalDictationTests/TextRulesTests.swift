import Foundation
import Testing
@testable import LocalDictation

@MainActor
struct TextRulesTests {
    let rules: TextRules

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString).json")
        try Data(#"{"replacements": [{"from": "jason", "to": "JSON"}], "vocabulary": ["Anneliese"]}"#.utf8).write(to: url)
        rules = TextRules(dictionaryURL: url)
    }

    func ctx(before: String = "", after: String = "", title: String = "") -> DictationContext {
        var c = DictationContext()
        c.before = before
        c.after = after
        c.windowTitle = title
        return c
    }

    @Test func emptyFieldIsUnchanged() {
        #expect(rules.fit("Send it tomorrow.", to: ctx()) == "Send it tomorrow.")
    }

    @Test func continuesSentenceInLowercaseWithSpace() {
        #expect(rules.fit("And then we ship it.", to: ctx(before: "We test first,")) == " and then we ship it.")
    }

    @Test func keepsCapitalAfterSentenceEnd() {
        #expect(rules.fit("Then we ship it.", to: ctx(before: "We test first.")) == " Then we ship it.")
    }

    @Test func keepsPronounIAndNames() {
        #expect(rules.fit("I think so.", to: ctx(before: "Honestly,")) == " I think so.")
        #expect(rules.fit("Aaliyah agrees.", to: ctx(before: "Also", title: "Chat with Aaliyah")) == " Aaliyah agrees.")
    }

    @Test func dropsPeriodAndAddsSpaceBeforeFollowingText() {
        #expect(rules.fit("Really quick.", to: ctx(before: "This is ", after: "update")) == "really quick ")
    }

    @Test func noSpaceAfterOpeningParen() {
        #expect(rules.fit("Maybe later.", to: ctx(before: "(", after: ")")) == "maybe later")
    }

    @Test func fixesNameSpellingFromScreen() {
        #expect(rules.fit("Ask Aliyah about it.", to: ctx(title: "Aaliyah — Messages")) == "Ask Aaliyah about it.")
    }

    @Test func fixesNameSpellingFromVocabulary() {
        #expect(rules.fit("Tell Annelise hi.", to: ctx()) == "Tell Anneliese hi.")
    }

    @Test func leavesCommonWordsAlone() {
        #expect(rules.fit("Ask Rain about it.", to: ctx(title: "Rowena")) == "Ask Rain about it.")
    }

    @Test func appliesReplacements() {
        #expect(rules.applyDictionary("Parse the jason file") == "Parse the JSON file")
    }
}
