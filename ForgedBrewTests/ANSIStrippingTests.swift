import Testing
@testable import ForgedBrew

// topgrade/brew output is peppered with ANSI colour codes and carriage-return
// in-place line rewrites (progress spinners). stripANSI has to reduce a chunk to
// what a terminal would actually render, or the streamed log turns to garbage.
struct ANSIStrippingTests {

    @Test func plainTextIsUnchanged() {
        #expect(TopgradeService.stripANSI("hello world") == "hello world")
        #expect(TopgradeService.stripANSI("") == "")
    }

    @Test func colourCodesAreStripped() {
        #expect(TopgradeService.stripANSI("\u{1B}[31mred\u{1B}[0m") == "red")
    }

    @Test func cursorAndEraseCodesAreStripped() {
        // ESC[2K (erase line) + ESC[1G (cursor to column 1).
        #expect(TopgradeService.stripANSI("\u{1B}[2K\u{1B}[1Gfoo") == "foo")
    }

    @Test func carriageReturnKeepsOnlyTheFinalRewrite() {
        // A status line rewritten in place: keep what's after the last \r.
        #expect(TopgradeService.stripANSI("old progress\rnew progress") == "new progress")
    }

    @Test func carriageReturnIsPerLine() {
        #expect(TopgradeService.stripANSI("a\rb\nc\rd") == "b\nd")
    }

    @Test func newlinesWithoutCarriageReturnsAredPreserved() {
        #expect(TopgradeService.stripANSI("line1\nline2") == "line1\nline2")
    }

    @Test func combinedColourAndRewrite() {
        // Colour codes stripped first, then the \r rewrite collapses to "100%".
        #expect(TopgradeService.stripANSI("\u{1B}[32m50%\r\u{1B}[32m100%") == "100%")
    }
}
