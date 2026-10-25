import Foundation
import Testing

@testable import omp_bridge

private let plainChangelog = ReleaseWorld.changelog([("1.0.0", ["The first release."])])
private let newerChangelog = ReleaseWorld.changelog([
    ("1.1.0", ["Updates itself from a release."]), ("1.0.0", ["The first release."]),
])

private func plainScenario(_ label: String) -> String { "\(label)-\(UUID().uuidString.prefix(8))" }

private func installedCurrent(_ label: String) -> (ReleaseMachine, String) {
    let world = ReleaseWorld.shared
    let scenario = plainScenario(label)
    #expect(world.publish(scenario, version: "1.0.0", changelog: plainChangelog))
    let (machine, ran) = ReleaseMachine.install(from: world.base(scenario))
    #expect(ran.status == 0, "\(ran.output)")
    return (machine, scenario)
}

private func attachQuiet(_ service: UpdateService) async {
    await service.attach(quiet: { MachineQuiet(quiet: true, turns: 0, reason: nil) }, settle: {})
}

@Suite struct PlainRestartTests {
    let world = ReleaseWorld.shared

    @Test func aRestartWithNothingWaitingIsRefusedUnlessAskedAnyway() async throws {
        let (installed, _) = installedCurrent("plain-refused")
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await attachQuiet(service)

        let (accepted, status) = await service.restart()
        #expect(!accepted)
        #expect(status.reason?.contains("already running the build") == true)
        #expect(status.job == nil)
        #expect(terminations.count == 0)
    }

    @Test func aRestartAskedAnywayWaitsForQuietAndHandsTheMachineToItsSupervisor() async throws {
        let (installed, _) = installedCurrent("plain-anyway")
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await attachQuiet(service)

        let (accepted, started) = await service.restart(anyway: true)
        #expect(accepted)
        #expect(started.job?.kind == .restart)
        #expect(started.job?.reloadOnly == true)

        let exited = await eventually { terminations.count > 0 }
        #expect(exited, "the bridge never handed itself to its supervisor")

        let after = await service.status(refreshing: false)
        #expect(after.job?.step == .restart || after.job?.step == .done)
        #expect(after.automation?.lastTakenAt == nil)
        #expect(installed.contents("build.json")?.contains("\"version\":\"1.0.0\"") == true)
    }

    @Test func aRestartAskedAnywayIsRefusedWhileAnUpdateIsUnderWay() async throws {
        let (installed, scenario) = installedCurrent("plain-busy")
        #expect(world.publish(scenario, version: "1.1.0", changelog: newerChangelog))
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await attachQuiet(service)

        let offered = await service.status(fetchingNow: true)
        #expect(offered.updateAvailable && offered.canUpdate)

        let (started, _) = await service.start()
        #expect(started)

        let (accepted, refused) = await service.restart(anyway: true)
        #expect(!accepted)
        #expect(refused.reason?.contains("under way") == true)

        let exited = await eventually { terminations.count > 0 }
        #expect(exited, "the update never handed itself to its supervisor")
    }
}
