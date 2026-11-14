import Foundation
import Testing

@testable import omp_bridge

/// A row nobody has read quotes the answer that closed its last turn. These pin which words are
/// the quote, which turns have none, and which rows are allowed to carry one.
@Suite struct LastWordsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ role: Role, _ parts: [Part]) -> Message {
        Message(
            id: UUID().uuidString, role: role, parts: parts, createdAt: now, seconds: nil,
            model: nil, usage: nil, costUSD: nil)
    }

    private func tool() -> Part {
        .tool(ToolCall(id: "c1", name: "read", input: "{}", status: .completed))
    }

    @Test func quotesTheNewestAnswerOfTheLastTurn() {
        let messages = [
            message(.user, [.text("first")]), message(.assistant, [.text("An older answer.")]),
            message(.user, [.text("second")]), message(.assistant, [.text("Working on it."), tool()]),
            message(.assistant, [.reasoning("thinking"), .text("**Shipped** 1.84 (222); it is `VALID`.")]),
        ]
        #expect(LastWords.quote(in: messages) == "Shipped 1.84 (222); it is VALID.")
    }

    @Test func aTurnThatEndedWithoutAWordQuotesNothing() {
        let messages = [
            message(.user, [.text("first")]), message(.assistant, [.text("An older answer.")]),
            message(.user, [.text("second")]), message(.assistant, [tool()]),
        ]
        #expect(LastWords.quote(in: messages) == nil)
        #expect(LastWords.quote(in: []) == nil)
    }

    @Test func aBracketThatOpensNoLinkDoesNotHideTheLinkAfterIt() {
        #expect(
            LastWords.digest("The index is at array[0]; see [the notes](https://example.com/a).")
                == "The index is at array[0]; see the notes.")
    }

    @Test func aLongAnswerIsCutAtAWord() throws {
        let digest = try #require(LastWords.digest(String(repeating: "seven letters ", count: 40)))
        #expect(digest.count <= LastWords.limit)
        #expect(digest.hasSuffix("…"))
    }

    @Test func theLedgerTakesTheQuoteOffAReadRow() {
        let moved = now.addingTimeInterval(-600)
        var summary = SessionSummary(
            id: "s1", title: "t", directory: nil, model: "m", effort: "", createdAt: moved,
            updatedAt: moved)
        summary.lastWords = "Done."
        var ledger = MarksLedger()
        #expect(ledger.stamping(summary, now: now).lastWords == "Done.")
        ledger.apply(MarkChange(read: .seen, at: now), to: "s1", updatedAt: moved, now: now)
        #expect(ledger.stamping(summary, now: now).lastWords == nil)
        let stale = now.addingTimeInterval(-LastWords.window - 60)
        #expect(!LastWords.mayBeUnread(updatedAt: stale, readAt: nil, now: now))
    }
}
