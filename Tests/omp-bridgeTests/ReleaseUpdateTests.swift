import Foundation
import Testing

@testable import omp_bridge

private let firstChangelog = ReleaseWorld.changelog([("1.0.0", ["The first release."])])
private let secondChangelog = ReleaseWorld.changelog([
    ("1.1.0", ["Updates itself from a release.", "Reports what is new."]),
    ("1.0.0", ["The first release."]),
])
private let thirdChangelog = ReleaseWorld.changelog([
    ("1.2.0", ["Third."]), ("1.1.0", ["Second."]), ("1.0.0", ["First."]),
])

private func machine(
    scenario: String, installed: String = "1.0.0", changelog: String = firstChangelog
) -> ReleaseMachine {
    let world = ReleaseWorld.shared
    #expect(world.publish(scenario, version: installed, changelog: changelog))
    let (machine, ran) = ReleaseMachine.install(from: world.base(scenario))
    #expect(ran.status == 0, "\(ran.output)")
    return machine
}

private func scenarioName(_ label: String) -> String { "\(label)-\(UUID().uuidString.prefix(8))" }

@Suite struct ReleaseCheckTests {
    let world = ReleaseWorld.shared

    @Test func theInstallerLeavesWhatTheBridgeNeedsToUpdateItself() throws {
        let installed = machine(scenario: scenarioName("kept"))
        let record = try #require(installed.contents("install.json"))
        #expect(record.contains("\"mode\":\"release\""))
        #expect(record.contains("\"base\":\"\(installed.base)\""))
        #expect(installed.contents("install.sh")?.hasPrefix("#!/usr/bin/env bash") == true)
        #expect(installed.contents("install.sh.sha256")?.count == 65)
        #expect(KeptInstaller(stateDirectory: installed.state).verdict() == .verified)
        #expect(installed.contents("build.json")?.contains("\"version\":\"1.0.0\"") == true)
    }

    @Test func aMachineBehindTheLatestReleaseIsOfferedIt() async throws {
        let scenario = scenarioName("behind")
        let installed = machine(scenario: scenario)
        world.publish(scenario, version: "1.1.0", changelog: secondChangelog)
        let status = await installed.service().status(fetchingNow: true)
        #expect(status.updateAvailable)
        #expect(status.version == OmpVersion.fallback)
        #expect(status.running == "1.0.0")
        #expect(status.latestVersion == "1.1.0")
        #expect(status.latestCommit == nil)
        #expect(status.source == nil)
        #expect(status.canUpdate)
        #expect(status.reason == nil)
        #expect(status.obstacle == nil)
        #expect(status.behind == nil)
        let remote = try #require(status.remote)
        #expect(remote.checked && remote.ok && remote.error == nil && remote.at != nil)
        let release = try #require(status.release)
        #expect(release.version == "1.1.0")
        #expect(release.commitsPastTag == 0)
        #expect(release.notes.count == 1)
        #expect(release.notes.first?.version == "1.1.0")
        #expect(release.notes.first?.date == "2026-10-01")
        #expect(
            release.notes.first?.items == ["Updates itself from a release.", "Reports what is new."])
        #expect(status.changes == release.notes.first?.items)
    }

    @Test func aCurrentMachineHasNothingToOffer() async throws {
        let scenario = scenarioName("current")
        let installed = machine(scenario: scenario)
        let status = await installed.service().status(fetchingNow: true)
        #expect(!status.updateAvailable)
        #expect(status.latestVersion == "1.0.0")
        #expect(status.canUpdate)
        #expect(status.remote?.ok == true)
        #expect(status.release?.version == "1.0.0")
        #expect(status.release?.notes.isEmpty == true)
        #expect(status.changes.isEmpty)
    }

    @Test func aMachineAheadOfThePointerIsNotOfferedAnOlderRelease() async throws {
        let scenario = scenarioName("ahead")
        let installed = machine(scenario: scenario, installed: "1.1.0", changelog: secondChangelog)
        world.publish(scenario, version: "1.0.0", changelog: firstChangelog)
        let status = await installed.service().status(fetchingNow: true)
        #expect(!status.updateAvailable)
        #expect(status.latestVersion == "1.0.0")
        #expect(status.remote?.ok == true)
    }

    @Test(arguments: ["banana", "1.2.x", "", "1..2", ".1", "1.", "v1.2.0", "1.2.0 beta", "99999999999999999999999999999.1"])
    func aPointerThatIsNotAVersionIsReportedAndNeverActedOn(_ pointer: String) async throws {
        let scenario = scenarioName("malformed")
        let installed = machine(scenario: scenario)
        world.publish(scenario, version: "1.1.0", changelog: secondChangelog, pointer: pointer)
        let status = await installed.service().status(fetchingNow: true)
        #expect(!status.updateAvailable)
        #expect(status.latestVersion == nil)
        let remote = try #require(status.remote)
        #expect(remote.checked && !remote.ok)
        #expect(remote.error?.contains("not readable") == true)
    }

    @Test func aReleaseServerThatHasNoReleaseSaysSo() async throws {
        let installed = machine(scenario: scenarioName("empty"))
        try? FileManager.default.removeItem(
            at: world.www.appendingPathComponent(installed.base.split(separator: "/").last.map(String.init)!)
                .appendingPathComponent("latest.txt"))
        let status = await installed.service().status(fetchingNow: true)
        #expect(!status.updateAvailable)
        #expect(status.remote?.ok == false)
        #expect(status.remote?.error == "No release has been published yet.")
    }

    @Test func aMachineThatCannotReachTheProjectSaysSoInsteadOfClaimingToBeCurrent() async throws {
        let installed = machine(scenario: scenarioName("offline"))
        let record = try #require(installed.contents("install.json"))
        try record.replacingOccurrences(of: installed.base, with: world.closedBase)
            .write(to: installed.state.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
        let status = await installed.service().status(fetchingNow: true)
        #expect(!status.updateAvailable)
        #expect(status.latestVersion == nil)
        let remote = try #require(status.remote)
        #expect(remote.checked && !remote.ok)
        #expect(remote.error?.hasPrefix("Could not reach") == true)
        #expect(status.canUpdate)
    }

    @Test func whatWasLastHeardSurvivesGoingOffline() async throws {
        let scenario = scenarioName("remembers")
        let installed = machine(scenario: scenario)
        world.publish(scenario, version: "1.1.0", changelog: secondChangelog)
        _ = await installed.service().status(fetchingNow: true)

        let cache = installed.state.appendingPathComponent("update.release.json")
        var snapshot = try #require(try? JSONCoding.decoder.decode(ReleaseSnapshot.self, from: Data(contentsOf: cache)))
        snapshot.checkedAt = Date().addingTimeInterval(-3600)
        try JSONCoding.encoder.encode(snapshot).write(to: cache)
        let record = try #require(installed.contents("install.json"))
        try record.replacingOccurrences(of: installed.base, with: world.closedBase)
            .write(to: installed.state.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)

        let status = await installed.service().status(fetchingNow: true)
        #expect(status.updateAvailable)
        #expect(status.latestVersion == "1.1.0")
        #expect(status.remote?.ok == false)
        #expect(status.remote?.error?.hasPrefix("Could not reach") == true)
    }

    @Test func theProjectIsAskedOncePerIntervalAndConditionallyAfterThat() async throws {
        let scenario = scenarioName("polite")
        let installed = machine(scenario: scenario)
        world.publish(scenario, version: "1.1.0", changelog: secondChangelog)
        let service = installed.service()
        for _ in 0..<5 { _ = await service.status() }
        _ = await service.status(fetchingNow: true)
        let first = world.requests(for: scenario).filter { $0.contains("latest.txt") && !$0.contains("1.0.0") }
        let pointerReads = world.requests(for: scenario).filter { $0.hasPrefix("/\(scenario)/latest.txt") }
        #expect(pointerReads.count == 2)
        #expect(first.count == 2)
        let changelogReads = world.requests(for: scenario).filter { $0.contains("CHANGELOG-1.1.0.md") }
        #expect(changelogReads.count == 1)

        let cache = installed.state.appendingPathComponent("update.release.json")
        var snapshot = try #require(try? JSONCoding.decoder.decode(ReleaseSnapshot.self, from: Data(contentsOf: cache)))
        snapshot.checkedAt = Date().addingTimeInterval(-3600)
        try JSONCoding.encoder.encode(snapshot).write(to: cache)
        let later = installed.restarted()
        let status = await later.status()
        #expect(status.updateAvailable)
        let after = world.requests(for: scenario).filter { $0.hasPrefix("/\(scenario)/latest.txt") }
        #expect(after.last == "/\(scenario)/latest.txt 304 conditional")
        #expect(world.requests(for: scenario).filter { $0.contains("CHANGELOG-1.1.0.md") }.count == 1)
    }

    @Test func theNotesCoverEveryReleaseBetweenWhatRunsAndWhatIsOffered() async throws {
        let scenario = scenarioName("notes")
        let installed = machine(scenario: scenario)
        world.publish(scenario, version: "1.2.0", changelog: thirdChangelog)
        let status = await installed.service().status(fetchingNow: true)
        let release = try #require(status.release)
        #expect(release.version == "1.2.0")
        #expect(release.notes.map(\.version) == ["1.2.0", "1.1.0"])
        #expect(release.notes.map(\.items) == [["Third."], ["Second."]])
    }

    @Test func aMissingChangelogCostsTheNotesAndNothingElse() async throws {
        let scenario = scenarioName("nonotes")
        let installed = machine(scenario: scenario)
        world.publish(scenario, version: "1.1.0", changelog: secondChangelog)
        try FileManager.default.removeItem(
            at: world.www.appendingPathComponent(scenario).appendingPathComponent("CHANGELOG-1.1.0.md"))
        let status = await installed.service().status(fetchingNow: true)
        #expect(status.updateAvailable)
        #expect(status.release?.notes.isEmpty == true)
        #expect(status.release?.version == "1.1.0")
        #expect(status.remote?.ok == true)
    }

    @Test func aBaseThatIsNeitherHttpsNorThisMachineIsNotTrusted() {
        #expect(ReleaseInstall.trustedBase("https://github.com/guitaripod/omp-bridge/releases/latest/download") != nil)
        #expect(ReleaseInstall.trustedBase("http://127.0.0.1:8000/x") != nil)
        #expect(ReleaseInstall.trustedBase("http://example.com/x") == nil)
        #expect(ReleaseInstall.trustedBase("ftp://127.0.0.1/x") == nil)
        #expect(ReleaseInstall.trustedBase("https://user:pw@example.com/x") == nil)
        #expect(ReleaseInstall.trustedBase("not a url") == nil)
    }

    @Test func aSourceInstallIsNotMistakenForARelease() throws {
        let installed = machine(scenario: scenarioName("source"))
        #expect(ReleaseInstall.read(stateDirectory: installed.state) != nil)
        try "{\"mode\":\"source\",\"repo\":\"x\",\"base\":\"https://example.com\"}"
            .write(to: installed.state.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
        #expect(ReleaseInstall.read(stateDirectory: installed.state) == nil)
        try "garbage".write(to: installed.state.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
        #expect(ReleaseInstall.read(stateDirectory: installed.state) == nil)
    }

    @Test func versionsAreComparedAsNumbersAndNotAsText() {
        let older = ReleaseVersion("1.9.0")!
        let newer = ReleaseVersion("1.10.0")!
        #expect(older.isOlder(than: newer))
        #expect(!newer.isOlder(than: older))
        #expect(!ReleaseVersion("2.0")!.isOlder(than: ReleaseVersion("2.0.0")!))
        #expect(ReleaseVersion("1.14.0-3-gabc1234")!.isOlder(than: ReleaseVersion("1.15.0")!))
    }
}
