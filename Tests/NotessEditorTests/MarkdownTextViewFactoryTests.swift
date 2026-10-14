import AppKit
import Testing
@testable import NotessEditor

@MainActor
@Suite("Markdown editor view")
struct MarkdownTextViewFactoryTests {
    @Test("the editor is an NSTextView on TextKit 2")
    func usesTextKit2() throws {
        let scrollView = MarkdownTextViewFactory.makeScrollView()
        let textView = try #require(scrollView.documentView as? NSTextView)

        // Never read `textView.layoutManager` here: doing so silently switches
        // the view to TextKit 1.
        #expect(textView.textLayoutManager != nil)
    }

    @Test("the editor edits plain text without typographic substitutions")
    func plainTextMarkdown() throws {
        let textView = try #require(MarkdownTextViewFactory.makeScrollView().documentView as? NSTextView)

        #expect(textView.isRichText == false)
        #expect(textView.isAutomaticQuoteSubstitutionEnabled == false)
        #expect(textView.isAutomaticDashSubstitutionEnabled == false)
        #expect(textView.allowsUndo)
    }
}
