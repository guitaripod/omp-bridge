import Foundation
import Testing

@testable import omp_bridge

private let firstChangelog = ReleaseWorld.changelog([("1.0.0", ["The first release."])])
private let secondChangelog = ReleaseWorld.changelog([
    ("1.1.0", ["Updates itself from a release."]), ("1.0.0", ["The first release."]),
])

private func scenarioName(_ label: String) -> String { "\(label)-\(UUID().uuidString.prefix(8))" }

private func installedAndBehind(_ label: String) -> (ReleaseMachine, String) {
    let world = ReleaseWorld.shared
    let scenario = scenarioName(label)
    #expect(world.publish(scenario, version: "1.0.0", changelog: firstChangelog))
    let (machine, ran) = ReleaseMachine.install(from: world.base(scenario))
    #expect(ran.status == 0, "\(ran.output)")
    #expect(world.publish(scenario, version: "1.1.0", changelog: secondChangelog))
    return (machine, scenario)
}

private func quiet(_ service: UpdateService) async {
    await service.attach(quiet: { MachineQuiet(quiet: true, turns: 0, reason: nil) }, settle: {})
}

@Suite struct ReleaseJobTests {
    let world = ReleaseWorld.shared

    @Test func aPressRunsTheKeptInstallerFromStartToASucceededJob() async throws {
        let (installed, scenario) = installedAndBehind("job")
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await quiet(service)
        let before = try #require(try? Data(contentsOf: installed.program))

        let offered = await service.status(fetchingNow: true)
        #expect(offered.updateAvailable && offered.canUpdate)

        let (accepted, started) = await service.start()
        #expect(accepted)
        #expect(started.job?.kind == .update)
        #expect(started.job?.automatic == false)
        #expect(started.job?.from == "1.0.0")
        #expect(started.job?.target == "1.1.0")
        #expect(started.phase == "running")

        let exited = await eventually { terminations.count > 0 }
        #expect(exited, "the bridge never handed itself to its supervisor")
        let after = try #require(try? Data(contentsOf: installed.program))
        #expect(after != before)
        let reported = Process()
        reported.executableURL = installed.program
        reported.arguments = ["--version"]
        let pipe = Pipe()
        reported.standardOutput = pipe
        try reported.run()
        reported.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "omp-bridge 1.1.0\n")
        #expect(installed.contents("build.json")?.contains("\"version\":\"1.1.0\"") == true)
        #expect(installed.contents("install.sh.sha256")?.count == 65)
        #expect(KeptInstaller(stateDirectory: installed.state).verdict() == .verified)
        #expect(installed.contents("update.state.json")?.contains("\"phase\":\"restarting\"") == true)

        let restarted = installed.restarted()
        await restarted.resume()
        let landed = await restarted.status(refreshing: false)
        let job = try #require(landed.job)
        #expect(job.isFinished)
        #expect(job.outcome == .succeeded)
        #expect(job.step == .done)
        #expect(job.from == "1.0.0")
        #expect(job.target == "1.1.0")
        #expect(job.landed == "1.1.0")
        #expect(landed.phase == "succeeded")
        #expect(landed.running == "1.1.0")
        #expect(!world.requests(for: scenario).isEmpty)
        #expect(
            world.requests(for: scenario).contains { $0.contains("omp-bridge-1.1.0-") && $0.contains(" 200 ") })
    }

    @Test func aChecksumThatDoesNotMatchLeavesTheOldProgramRunning() async throws {
        let (installed, scenario) = installedAndBehind("badsum")
        world.spoilChecksum(scenario, version: "1.1.0")
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await quiet(service)
        let program = try #require(try? Data(contentsOf: installed.program))
        let stamp = installed.contents("build.json")
        let config = installed.config
        let installer = installed.contents("install.sh")

        _ = await service.status(fetchingNow: true)
        let (accepted, _) = await service.start()
        #expect(accepted)
        let ended = await eventually { await service.status(refreshing: false).job?.isFinished == true }
        #expect(ended)

        let status = await service.status(refreshing: false)
        let job = try #require(status.job)
        #expect(job.outcome == .failed)
        #expect(job.step == .download)
        #expect(job.reason == "The download did not match its checksum and was thrown away")
        #expect(job.landed == "1.0.0")
        #expect(status.phase == "failed")
        #expect(terminations.count == 0)
        #expect((try? Data(contentsOf: installed.program)) == program)
        #expect(installed.contents("build.json") == stamp)
        #expect(installed.config == config)
        #expect(installed.contents("install.sh") == installer)
        #expect(!FileManager.default.fileExists(atPath: installed.home.appendingPathComponent(".local/bin/.omp-bridge.new").path))
    }

    @Test func aMachineThatFailedToTakeAReleaseIsNotAskedToTryItAgainAtOnce() async throws {
        let (installed, scenario) = installedAndBehind("backoff")
        world.spoilChecksum(scenario, version: "1.1.0")
        let service = installed.service()
        await quiet(service)
        _ = await service.setAutomation(enabled: true)
        await service.considerUpdating()
        let held = await eventually { await service.status(refreshing: false).automation?.holdingOff != nil }
        #expect(held)
        let first = world.requests(for: scenario).filter { $0.contains("omp-bridge-1.1.0-") }.count
        #expect(first > 0)

        let status = await service.status(fetchingNow: true)
        #expect(status.job?.automatic == true)
        #expect(status.job?.outcome == .failed)
        #expect(status.automation?.enabled == true)
        #expect(status.automation?.holdingOff?.contains("1.1.0") == true)
        await service.considerUpdating()
        try await Task.sleep(for: .milliseconds(500))
        #expect(world.requests(for: scenario).filter { $0.contains("omp-bridge-1.1.0-") }.count == first)
        #expect(await service.status(refreshing: false).job?.id == status.job?.id)
    }

    @Test func anUnattendedMachineTakesTheReleaseItself() async throws {
        let (installed, _) = installedAndBehind("auto")
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await quiet(service)

        let enabled = await service.setAutomation(enabled: true)
        #expect(enabled.automation?.enabled == true)
        #expect(enabled.automation?.holdingOff == nil)
        #expect(enabled.automation?.nextLookAt != nil)
        #expect(enabled.updateAvailable)

        await service.considerUpdating()
        let exited = await eventually { terminations.count > 0 }
        #expect(exited)

        let restarted = installed.restarted()
        await restarted.resume()
        let status = await restarted.status(refreshing: false)
        #expect(status.job?.automatic == true)
        #expect(status.job?.outcome == .succeeded)
        #expect(status.automation?.enabled == true)
        #expect(status.automation?.lastTarget == "1.1.0")
        #expect(status.automation?.lastTakenAt != nil)
    }

    @Test func aMachineWithNothingToStartItAgainKeepsTheNewProgramOnDisk() async throws {
        let (installed, _) = installedAndBehind("manual")
        let terminations = Counter()
        let service = installed.service(manager: "manual", terminations: terminations)
        await quiet(service)
        let offered = await service.status(fetchingNow: true)
        #expect(offered.canUpdate)
        #expect(offered.reason?.contains("start it again yourself") == true)
        _ = await service.start()
        let ended = await eventually { await service.status(refreshing: false).job?.isFinished == true }
        #expect(ended)
        let job = await service.status(refreshing: false).job
        #expect(job?.outcome == .deferred)
        #expect(terminations.count == 0)
        #expect(installed.contents("build.json")?.contains("\"version\":\"1.1.0\"") == true)
    }

    @Test func aChangedInstallerIsNeverRun() async throws {
        let (installed, scenario) = installedAndBehind("tampered")
        let script = installed.state.appendingPathComponent("install.sh")
        try ((installed.contents("install.sh") ?? "") + "\ntouch \"$HOME/pwned\"\n")
            .write(to: script, atomically: true, encoding: .utf8)
        let service = installed.service()
        await quiet(service)
        let status = await service.status(fetchingNow: true)
        #expect(status.updateAvailable)
        #expect(!status.canUpdate)
        #expect(status.obstacle?.kind == "installerChanged")
        let (accepted, refused) = await service.start()
        #expect(!accepted)
        #expect(refused.job == nil)
        #expect(!FileManager.default.fileExists(atPath: installed.home.appendingPathComponent("pwned").path))
        #expect(world.requests(for: scenario).filter { $0.contains("omp-bridge-1.1.0-") }.isEmpty)
    }

    @Test func aMachineWithoutTheKeptInstallerSaysHowToGetOne() async throws {
        let (installed, _) = installedAndBehind("noinstaller")
        try FileManager.default.removeItem(at: installed.state.appendingPathComponent("install.sh"))
        let status = await installed.service().status(fetchingNow: true)
        #expect(status.updateAvailable)
        #expect(!status.canUpdate)
        #expect(status.obstacle?.kind == "noInstaller")
        #expect(status.reason?.contains("install command") == true)
    }
}
