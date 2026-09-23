import Foundation
import Testing

@testable import omp_bridge

/// An update is followed by clients that were not there when it started and judged by a process
/// that did not start it, so the job's rules — how it moves, how it ends, and what it says the new
/// build carries — are pinned here.
@Suite struct UpdateJobTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aJobOnlyMovesForward() {
        var job = UpdateJob.begin(.update, automatic: false, from: "1.9.2", target: "1.10.0", now: start)
        #expect(job.step == .download)
        job.advance(to: .build, now: start.addingTimeInterval(5))
        job.advance(to: .download, now: start.addingTimeInterval(6))
        #expect(job.step == .build)
        #expect(job.stepStartedAt == start.addingTimeInterval(5))
    }

    /// A poll that reads a stale phase after the job ended must not reopen it.
    @Test func aFinishedJobNeverMovesAgain() {
        var job = UpdateJob.begin(.update, automatic: true, from: "1.9.2", target: "1.10.0", now: start)
        job.finish(.failed, reason: "It broke", now: start.addingTimeInterval(60))
        job.advance(to: .restart)
        job.finish(.succeeded)
        #expect(job.outcome == .failed)
        #expect(job.reason == "It broke")
        #expect(job.step == .download)
    }

    @Test func aRestartJobBeginsAtTheWait() {
        let job = UpdateJob.begin(.restart, automatic: false, from: "1.9.2", target: "1.10.0")
        #expect(job.step == .waitForIdle)
    }

    /// The process that comes back decides how an update ended by what it is running: a binary
    /// made during the job is the job's, one older than the job is the build it already had.
    @Test func theProcessThatComesBackJudgesTheUpdate() {
        var job = UpdateJob.begin(.update, automatic: false, from: "1.9.2", target: "1.10.0", now: start)
        job.advance(to: .restart)
        let landed = UpdateJob.conclusion(
            of: job, runningBuiltAt: start.addingTimeInterval(200),
            processStarted: start.addingTimeInterval(260), restartStillOwed: false)
        #expect(landed.0 == .succeeded)

        let stale = UpdateJob.conclusion(
            of: job, runningBuiltAt: start.addingTimeInterval(-86_400),
            processStarted: start.addingTimeInterval(260), restartStillOwed: false)
        #expect(stale.0 == .failed)
        #expect(stale.1 != nil)
    }

    @Test func aRestartThatLeftABuildWaitingDidNotLandIt() {
        let job = UpdateJob.begin(.restart, automatic: false, from: "1.9.2", target: "1.10.0", now: start)
        let owed = UpdateJob.conclusion(
            of: job, runningBuiltAt: nil, processStarted: start.addingTimeInterval(30),
            restartStillOwed: true)
        #expect(owed.0 == .failed)
        let clean = UpdateJob.conclusion(
            of: job, runningBuiltAt: nil, processStarted: start.addingTimeInterval(30),
            restartStillOwed: false)
        #expect(clean.0 == .succeeded)
    }

    @Test func theInstallersOwnRefusalIsTheReason() {
        let log = """
            updating /home/me/.claude-bridge/src
            building (this takes a few minutes the first time)
            error: only 900 MB free where the checkout lives; the build needs about 2 GB
            """
        #expect(
            InstallerLog.failure(in: log)
                == "Only 900 MB free where the checkout lives; the build needs about 2 GB")
        #expect(InstallerLog.failure(in: "compiling\nlinking") == nil)
    }

    @Test func installerPhasesMapToSteps() {
        #expect(UpdateJob.Step(installerPhase: "running") == .download)
        #expect(UpdateJob.Step(installerPhase: "building") == .build)
        #expect(UpdateJob.Step(installerPhase: "restarting") == .restart)
        #expect(UpdateJob.Step(installerPhase: "succeeded") == nil)
    }

    @Test func theChangelogIsReadIntoReleases() {
        let notes = Changelog.parse(
            """
            # Changelog

            ## Unreleased

            - Something past the tag

            ## [1.10.0] — 2026-09-23

            - First line
              continues here
            - Second line

            ## v1.9.2 - 2026-09-20
            * Older
            """)
        #expect(notes.count == 3)
        #expect(notes[0].version == nil)
        #expect(notes[0].items == ["Something past the tag"])
        #expect(notes[1].version == "1.10.0")
        #expect(notes[1].date == "2026-09-23")
        #expect(notes[1].items == ["First line continues here", "Second line"])
        #expect(notes[2].version == "1.9.2")
        #expect(notes[2].items == ["Older"])
    }

    /// Only what is newer than the running build is news, and a build past its tag already has
    /// that tag's release.
    @Test func onlyNewerReleasesAreReported() {
        let changelog = """
            ## 1.10.0 — 2026-09-23
            - New
            ## 1.9.2 — 2026-09-20
            - Old
            """
        let release = UpdateRelease.assemble(
            changelog: changelog, running: "1.9.2-1-ge877732", tag: "1.10.0", commitsPastTag: 0,
            untaggedSubjects: [], newSubjects: ["Something: long paragraph"])
        #expect(release.version == "1.10.0")
        #expect(release.notes.map(\.version) == ["1.10.0"])
        #expect(release.notes.first?.items == ["New"])
    }

    /// With no changelog to read, the commits' own headlines stand in rather than nothing.
    @Test func withoutAChangelogTheHeadlinesStandIn() {
        let release = UpdateRelease.assemble(
            changelog: "", running: "1.9.1", tag: "1.9.2", commitsPastTag: 0,
            untaggedSubjects: [],
            newSubjects: [
                "An agent is out on evidence, not on a clock: a nested agent is answered where it reports"
            ])
        #expect(release.notes.count == 1)
        #expect(release.notes[0].version == "1.9.2")
        #expect(release.notes[0].items == ["An agent is out on evidence, not on a clock"])
    }

    @Test func workPastTheNewestTagLeadsTheNotes() {
        let release = UpdateRelease.assemble(
            changelog: "## 1.10.0\n- Tagged", running: "1.9.2", tag: "1.10.0", commitsPastTag: 2,
            untaggedSubjects: ["Fixes a thing: because", "adds another — with detail"],
            newSubjects: [])
        #expect(release.notes.map(\.version) == [nil, "1.10.0"])
        #expect(release.notes[0].items == ["Fixes a thing", "Adds another"])
    }

    @Test func aHeadlineIsTheClaimNotTheParagraph() {
        #expect(CommitHeadline.short("Silence is not work: a turn nothing ever answered") == "Silence is not work")
        #expect(CommitHeadline.short("short: tail") == "Short: tail")
        let long = String(repeating: "word ", count: 60)
        let cut = CommitHeadline.short(long)
        #expect(cut.count <= CommitHeadline.limit + 1)
        #expect(cut.hasSuffix("…"))
    }

    @Test func releaseVersionsCompareByNumber() {
        #expect(ReleaseVersion("1.9.2")!.isOlder(than: ReleaseVersion("1.10.0")!))
        #expect(!ReleaseVersion("1.10.0")!.isOlder(than: ReleaseVersion("1.9.2")!))
        #expect(!ReleaseVersion("v1.9.2-3-gabcdef1")!.isOlder(than: ReleaseVersion("1.9.2")!))
        #expect(ReleaseVersion("e877732") == nil)
    }
}
