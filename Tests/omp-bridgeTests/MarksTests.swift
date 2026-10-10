import Foundation
import Testing

@testable import omp_bridge

/// What a person decides about a conversation lives on the machine that holds it, so every client
/// reads one answer. The promise under test: the later decision wins whatever order they arrive in,
/// and the bridge's own clock — never a client's — decides what is unread.
@Suite struct MarksTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    private func summary(_ id: String = "s", updatedAt: Date? = nil) -> SessionSummary {
        SessionSummary(
            id: id, title: "Chat", directory: nil, model: "sonnet", effort: "medium",
            createdAt: at(-1000), updatedAt: updatedAt ?? at(-100))
    }

    private func marked(_ change: MarkChange, updatedAt: Date? = nil) -> SessionMarks {
        var marks = SessionMarks()
        marks.apply(change, updatedAt: updatedAt, now: now)
        return marks
    }

    @Test func aLaterDecisionWinsAndAnEqualOneApplies() {
        var marks = marked(MarkChange(pinned: true, at: at(-60)))
        marks.apply(MarkChange(pinned: false, at: at(-30)), updatedAt: nil, now: now)
        #expect(marks.pinned == MarkDecision(on: false, at: at(-30)))
        marks.apply(MarkChange(pinned: true, at: at(-30)), updatedAt: nil, now: now)
        #expect(marks.pinned == MarkDecision(on: true, at: at(-30)))
    }

    @Test func aStaleDecisionDeliveredLateIsIgnored() {
        var marks = marked(MarkChange(archived: true, at: at(-10)))
        marks.apply(MarkChange(archived: false, at: at(-500)), updatedAt: nil, now: now)
        #expect(marks.archived == MarkDecision(on: true, at: at(-10)))
    }

    @Test func eachMarkIsDecidedOnItsOwn() {
        var marks = marked(MarkChange(saved: true, pinned: true, at: at(-10)))
        marks.apply(MarkChange(saved: false, pinned: false, archived: true, at: at(-50)), updatedAt: nil, now: now)
        #expect(marks.saved?.on == true)
        #expect(marks.pinned?.on == true)
        #expect(marks.archived == MarkDecision(on: true, at: at(-50)))
    }

    @Test func aSkewedClientClockCannotWinForever() {
        var marks = marked(MarkChange(pinned: true, at: at(7200)))
        #expect(marks.pinned?.at == at(300))
        marks.apply(MarkChange(pinned: false, at: at(301)), updatedAt: nil, now: now)
        #expect(marks.pinned?.on == false)
    }

    @Test func aDecisionWithNoTimeIsMadeNow() {
        let marks = marked(MarkChange(saved: true))
        #expect(marks.saved == MarkDecision(on: true, at: now))
    }

    @Test func decisionTimesKeepWholeSecondsSoTheySurviveARestart() {
        let marks = marked(MarkChange(saved: true, at: at(-10.75)))
        #expect(marks.saved?.at == at(-11))
    }

    @Test func seenIsStampedWithTheBridgesClock() {
        let marks = marked(MarkChange(read: .seen, at: at(-9000)), updatedAt: at(-100))
        #expect(marks.readAt == now)
        #expect(marks.readDecided == at(-9000))
    }

    @Test func unreadSitsTwoSecondsBeforeTheChatLastMoved() {
        let updated = at(-100)
        let marks = marked(MarkChange(read: .unread), updatedAt: updated)
        #expect(marks.readAt == at(-102))
        let moved = marks.readAt.map { updated > $0.addingTimeInterval(1) }
        #expect(moved == true)
    }

    @Test func unreadOfAChatTheBridgeCannotDateFallsBackToNow() {
        #expect(marked(MarkChange(read: .unread)).readAt == at(-2))
    }

    @Test func seenOnAChatAlreadyReadPastItsLastMovementChangesNothingVisible() {
        var marks = marked(MarkChange(read: .seen, at: at(-50)), updatedAt: at(-100))
        let before = marks.readAt
        marks.apply(MarkChange(read: .seen, at: at(-20)), updatedAt: at(-100), now: at(60))
        #expect(marks.readAt == before)
        #expect(marks.readDecided == at(-20))
    }

    @Test func aLateUnreadOlderThanTheLastLookLoses() {
        var marks = marked(MarkChange(read: .seen, at: at(-10)), updatedAt: at(-100))
        marks.apply(MarkChange(read: .unread, at: at(-40)), updatedAt: at(-100), now: now)
        #expect(marks.readAt == now)
    }

    @Test func aChatThatMovedAfterTheLookIsUnreadAgainUntilSeen() {
        var marks = marked(MarkChange(read: .seen), updatedAt: at(-100))
        marks.apply(MarkChange(read: .seen, at: at(20)), updatedAt: at(10), now: at(20))
        #expect(marks.readAt == at(20))
    }

    @Test func aMarkThatChangesNothingLeavesNoEntryBehind() {
        var ledger = MarksLedger()
        let changed = ledger.apply(MarkChange(), to: "s", updatedAt: nil, now: now)
        #expect(!changed)
        #expect(ledger.entries.isEmpty)
    }

    @Test func aRepeatedMarkIsNotAChange() {
        var ledger = MarksLedger()
        let first = ledger.apply(MarkChange(saved: true, at: at(-5)), to: "s", updatedAt: nil, now: now)
        let again = ledger.apply(MarkChange(saved: true, at: at(-5)), to: "s", updatedAt: nil, now: now)
        #expect(first)
        #expect(!again)
    }

    @Test func stampingAlwaysSaysPinnedAndArchivedAndOnlySometimesWhen() {
        var ledger = MarksLedger()
        let bare = ledger.stamping(summary())
        #expect(bare.saved == false)
        #expect(bare.pinned == false)
        #expect(bare.archived == false)
        #expect(bare.pinnedAt == nil)
        #expect(bare.readAt == nil)
        ledger.apply(MarkChange(pinned: true, at: at(-30)), to: "s", updatedAt: nil, now: now)
        ledger.apply(MarkChange(read: .seen), to: "s", updatedAt: nil, now: now)
        let pinned = ledger.stamping(summary())
        #expect(pinned.pinned == true)
        #expect(pinned.pinnedAt == at(-30))
        #expect(pinned.readAt == now)
        ledger.apply(MarkChange(pinned: false, at: at(-10)), to: "s", updatedAt: nil, now: now)
        #expect(ledger.stamping(summary()).pinnedAt == nil)
    }

    @Test func aMarkChangeIsAChangeToTheSummaryTheObserverDiffs() {
        var ledger = MarksLedger()
        let before = ledger.stamping(summary())
        ledger.apply(MarkChange(archived: true), to: "s", updatedAt: nil, now: now)
        #expect(ledger.stamping(summary()) != before)
        let settled = ledger.stamping(summary())
        ledger.apply(MarkChange(archived: true, at: at(-1)), to: "s", updatedAt: nil, now: now)
        #expect(ledger.stamping(summary()) == settled)
    }

    private func keys(_ summary: SessionSummary) throws -> Set<String> {
        let data = try WireCoding.encoder.encode(summary)
        return Set(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
    }

    @Test func theWireShapeCarriesPinnedAndArchivedEvenWhenFalse() throws {
        var ledger = MarksLedger()
        let plain = try keys(ledger.stamping(summary()))
        #expect(plain.isSuperset(of: ["saved", "pinned", "archived"]))
        #expect(!plain.contains("pinnedAt"))
        #expect(!plain.contains("readAt"))
        ledger.apply(MarkChange(pinned: true, read: .seen), to: "s", updatedAt: nil, now: now)
        let marked = try keys(ledger.stamping(summary()))
        #expect(marked.isSuperset(of: ["saved", "pinned", "pinnedAt", "archived", "readAt"]))
    }

    @Test func aBridgeThatNeverStampedSaysNothingOfMarks() throws {
        let bare = try keys(summary())
        #expect(bare.isDisjoint(with: ["saved", "pinned", "pinnedAt", "archived", "readAt"]))
    }

    private func patch(_ json: String) throws -> SessionPatch {
        try WireCoding.decoder.decode(SessionPatch.self, from: Data(json.utf8))
    }

    @Test func aPatchNamingNoMarkAndNoTitleIsEmpty() throws {
        #expect(try patch("{}").isEmpty)
        #expect(try patch(#"{"at":"2026-10-10T10:00:00Z"}"#).isEmpty)
        #expect(try patch(#"{"title":"   "}"#).isEmpty)
    }

    @Test func aPatchNamingAnyOneThingIsNotEmpty() throws {
        for body in [
            #"{"title":"New"}"#, #"{"saved":false}"#, #"{"pinned":true}"#,
            #"{"archived":false}"#, #"{"read":"seen"}"#, #"{"read":"unread"}"#,
        ] {
            #expect(try !patch(body).isEmpty, "\(body)")
        }
    }

    @Test func aPatchCarriesTheDecisionTimeAndRefusesAnUnknownReadWord() throws {
        let decoded = try patch(#"{"pinned":true,"read":"seen","at":"2026-10-10T10:00:00Z"}"#)
        #expect(decoded.marks.pinned == true)
        #expect(decoded.marks.read == .seen)
        #expect(decoded.marks.at == Date(timeIntervalSince1970: 1_791_626_400))
        #expect(throws: (any Error).self) { try patch(#"{"read":"maybe"}"#) }
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marks-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func theLedgerSurvivesARestartExactly() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var ledger = MarksLedger()
        ledger.apply(
            MarkChange(saved: true, pinned: true, archived: false, read: .unread, at: at(-5)),
            to: "a", updatedAt: at(-100), now: now)
        ledger.apply(MarkChange(saved: false, at: at(-9)), to: "b", updatedAt: nil, now: now)
        ledger.write(to: root.appendingPathComponent("marks.json"))
        let reloaded = MarksLedger.load(from: root.appendingPathComponent("marks.json"), now: now)
        #expect(reloaded == ledger)
    }

    @Test func theFileHasTheDocumentedShape() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var ledger = MarksLedger()
        ledger.apply(MarkChange(pinned: true, read: .seen, at: at(-5)), to: "a", updatedAt: nil, now: now)
        let url = root.appendingPathComponent("marks.json")
        ledger.write(to: url)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
        let entry = try #require(object["a"])
        let pinned = try #require(entry["pinned"] as? [String: Any])
        #expect(pinned["on"] as? Bool == true)
        #expect(pinned["at"] is String)
        #expect(entry["readAt"] is String)
        #expect(entry["readDecided"] is String)
        #expect(entry["saved"] == nil)
    }

    @Test func aLedgerWithNoFilesIsEmpty() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = MarksLedger.load(from: root.appendingPathComponent("marks.json"), now: now)
        #expect(ledger.entries.isEmpty)
    }

    @Test func pruneForgetsOnlyWhatNothingHasListedForAMonth() {
        var ledger = MarksLedger()
        for id in ["gone", "listed", "recent"] {
            ledger.apply(MarkChange(pinned: true), to: id, updatedAt: nil, now: now)
        }
        let later = now.addingTimeInterval(MarksLedger.pruneAfter + 3600)
        ledger.noteListed(["recent"], now: later.addingTimeInterval(-3600))
        let dropped = ledger.prune(listed: ["listed"], now: later)
        #expect(dropped)
        #expect(Set(ledger.entries.keys) == ["listed", "recent"])
        let droppedAgain = ledger.prune(listed: ["listed"], now: later)
        #expect(!droppedAgain)
    }

    @Test func aSightingIsOnlyWrittenDownWhenItIsADayStale() {
        var ledger = MarksLedger()
        ledger.apply(MarkChange(saved: true), to: "s", updatedAt: nil, now: now)
        let soon = ledger.noteListed(["s", "unmarked"], now: now.addingTimeInterval(3600))
        let stale = ledger.noteListed(["s"], now: now.addingTimeInterval(MarksLedger.listedGrain + 1))
        #expect(!soon)
        #expect(stale)
    }

    private func makeStore(_ root: URL) -> SessionStore {
        SessionStore(path: root.appendingPathComponent("sessions.json").path)
    }

    @Test func theStoreMarksAnyIdAndKeepsItAcrossARestart() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        #expect(await store.applyMarks("discovered", MarkChange(saved: true, pinned: true), updatedAt: nil))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("marks.json").path))
        #expect(await store.applyMarks("discovered", MarkChange(pinned: false), updatedAt: nil))
        let reopened = makeStore(root)
        let stamped = await reopened.stampingMarks([summary("discovered")])
        #expect(stamped.first?.saved == true)
        #expect(stamped.first?.pinned == false)
    }

    @Test func forgettingAConversationTakesItsMarksWithIt() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        await store.applyMarks("gone", MarkChange(saved: true, archived: true), updatedAt: nil)
        await store.applyMarks("other", MarkChange(pinned: true), updatedAt: nil)
        await store.forgetMarks("gone")
        let reopened = makeStore(root)
        let stamped = await reopened.stampingMarks([summary("gone"), summary("other")])
        #expect(stamped[0].saved == false)
        #expect(stamped[0].archived == false)
        #expect(stamped[1].pinned == true)
    }

    @Test func theStoreOnlyPrunesWhatHasGoneUnlisted() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        await store.applyMarks("kept", MarkChange(pinned: true), updatedAt: nil)
        await store.applyMarks("gone", MarkChange(pinned: true), updatedAt: nil)
        let later = Date().addingTimeInterval(MarksLedger.pruneAfter + 3600)
        await store.pruneMarks(listed: ["kept"], now: later)
        let stamped = await store.stampingMarks([summary("kept"), summary("gone")], now: later)
        #expect(stamped[0].pinned == true)
        #expect(stamped[1].pinned == false)
    }

    @Test func aBridgeThatHoldsMarksSaysSoInItsStatus() throws {
        let status = BridgeStatus(
            agent: "omp", model: "", version: "x", authenticated: true, proto: 2, epoch: "e",
            turnWait: 1, marks: 1)
        let data = try WireCoding.encoder.encode(status)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["marks"] as? Int == 1)
    }
}
