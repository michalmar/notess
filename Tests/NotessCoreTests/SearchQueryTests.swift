import Foundation
import Testing
@testable import NotessCore

@Suite("Parsing search queries")
struct SearchQueryTests {
    @Test("#tag words filter by Tag, the rest is fulltext")
    func tagsAndTerms() {
        let query = SearchQuery("#Acme kickoff #projekt-x plán")
        #expect(query.tags == ["acme", "projekt-x"])
        #expect(query.terms == ["kickoff", "plán"])
    }

    @Test("a Tag with diacritics is recognised and normalised")
    func diacriticTag() {
        #expect(SearchQuery("#Ranní").tags == ["ranní"])
    }

    @Test("a hash that does not start a Tag is plain text")
    func notATag() {
        let query = SearchQuery("#2026 # C#")
        #expect(query.tags.isEmpty)
        #expect(query.terms == ["#2026", "#", "C#"])
    }

    @Test("an empty or blank query is empty")
    func empty() {
        #expect(SearchQuery("").isEmpty)
        #expect(SearchQuery("  \n ").isEmpty)
        #expect(!SearchQuery("#acme").isEmpty)
    }

    @Test("terms become quoted prefix searches; punctuation-only terms are dropped")
    func ftsExpression() {
        #expect(SearchQuery("kick off").ftsExpression == "\"kick\"* \"off\"*")
        #expect(SearchQuery("say \"hi\"").ftsExpression == "\"say\"* \"\"\"hi\"\"\"*")
        #expect(SearchQuery("#acme - ").ftsExpression == nil)
    }

    @Test("Unicode normalisation does not matter")
    func normalisation() {
        let decomposed = "pr\u{030C}ehled"
        #expect(SearchQuery(decomposed).terms == ["přehled"])
    }
}
