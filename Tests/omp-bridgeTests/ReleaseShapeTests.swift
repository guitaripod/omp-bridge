import Foundation
import Testing

@testable import omp_bridge

private let firstChangelog = ReleaseWorld.changelog([("1.0.0", ["The first release."])])
private let secondChangelog = ReleaseWorld.changelog([
    ("1.1.0", ["Updates itself from a release.", "Reports what is new."]),
    ("1.0.0", ["The first release."]),
])

private func git(_ arguments: [String], in directory: URL) {
    let ran = run(
        "/usr/bin/env",
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
            + arguments,
        in: directory)
    #expect(ran.status == 0, "git \(arguments.joined(separator: " ")): \(ran.output)")
}

private func sourceCheckout() throws -> URL {
    let root = makeTemporaryDirectory("source-path")
    let origin = root.appendingPathComponent("origin.git")
    let work = root.appendingPathComponent("work")
    let checkout = root.appendingPathComponent("checkout")
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    git(["init", "--bare", "-b", "master", "."], in: origin)
    git(["clone", origin.path, work.path], in: root)
    try firstChangelog.write(to: work.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
    try "#!/usr/bin/env bash\n".write(to: work.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
    try "// swift-tools-version:6.0\n".write(to: work.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    git(["checkout", "-B", "master"], in: work)
    git(["add", "."], in: work)
    git(["commit", "-m", "1.0.0"], in: work)
    git(["tag", "1.0.0"], in: work)
    git(["push", "-u", "origin", "master", "--tags"], in: work)
    git(["clone", origin.path, checkout.path], in: root)
    try secondChangelog.write(to: work.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
    git(["commit", "-am", "1.1.0"], in: work)
    git(["tag", "1.1.0"], in: work)
    git(["push", "origin", "master", "--tags"], in: work)
    return checkout
}

private indirect enum JSONKind: Decodable {
    case object([String: JSONKind])
    case array([JSONKind])
    case string, number, bool, null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if (try? container.decode(Bool.self)) != nil { self = .bool }
        else if (try? container.decode(Double.self)) != nil { self = .number }
        else if (try? container.decode(String.self)) != nil { self = .string }
        else if let items = try? container.decode([JSONKind].self) { self = .array(items) }
        else { self = .object(try container.decode([String: JSONKind].self)) }
    }

    func shape(at path: String = "") -> [String: String] {
        switch self {
        case .object(let fields):
            var result = [path: "object"]
            for (key, nested) in fields { result.merge(nested.shape(at: "\(path).\(key)")) { first, _ in first } }
            return result
        case .array(let items):
            var result = [path: "array"]
            for item in items { result.merge(item.shape(at: "\(path)[]")) { first, _ in first } }
            return result
        case .string: return [path: "string"]
        case .number: return [path: "number"]
        case .bool: return [path: "bool"]
        case .null: return [path: "null"]
        }
    }
}

private func shape<T: Encodable>(_ value: T) -> [String: String] {
    let data = (try? JSONCoding.encoder.encode(value)) ?? Data()
    return (try? JSONDecoder().decode(JSONKind.self, from: data))?.shape() ?? [:]
}

@Suite struct ReleaseShapeTests {
    @Test func theOfferAReleaseInstallMakesIsTheOfferACheckoutMakes() async throws {
        let world = ReleaseWorld.shared
        let scenario = "shape-\(UUID().uuidString.prefix(8))"
        #expect(world.publish(scenario, version: "1.0.0", changelog: firstChangelog))
        let (installed, ran) = ReleaseMachine.install(from: world.base(scenario))
        #expect(ran.status == 0, "\(ran.output)")
        #expect(world.publish(scenario, version: "1.1.0", changelog: secondChangelog))
        let releaseService = installed.service()
        await releaseService.attach(quiet: { MachineQuiet(quiet: true, turns: 0, reason: nil) }, settle: {})
        let release = await releaseService.status(fetchingNow: true)

        let checkout = try sourceCheckout()
        let stamp = OmpVersion.Stamp(
            version: "1.0.0", commit: "abc1234", builtAt: Date(), source: checkout.path)
        let sourceService = UpdateService(
            stateDirectory: makeTemporaryDirectory("source-state"), sourceOverride: checkout.path,
            deriveSource: false,
            hooks: UpdateHooks(
                manager: { "systemd" }, stamp: { stamp }, terminate: {}, home: checkout.path))
        await sourceService.attach(quiet: { MachineQuiet(quiet: true, turns: 0, reason: nil) }, settle: {})
        let source = await sourceService.status(fetchingNow: true)

        #expect(source.updateAvailable, "the checkout fixture is not behind its origin")
        #expect(source.canUpdate)
        #expect(source.remote?.ref == "origin/master")

        let releaseShape = shape(release)
        let sourceShape = shape(source)
        for (path, kind) in releaseShape {
            #expect(sourceShape[path] == kind, "\(path) is \(kind) here and \(sourceShape[path] ?? "absent") from a checkout")
        }

        let read = [
            ".version", ".running", ".restartRequired", ".updateAvailable", ".latestVersion",
            ".changes", ".canUpdate", ".manager", ".phase", ".canRestart", ".busy", ".busy.quiet",
            ".busy.turns", ".automation", ".automation.enabled", ".remote", ".remote.checked",
            ".remote.ok", ".remote.at", ".remote.ref", ".release", ".release.version",
            ".release.commitsPastTag", ".release.notes", ".release.notes[]",
            ".release.notes[].version", ".release.notes[].date", ".release.notes[].items",
        ]
        for path in read {
            #expect(releaseShape[path] != nil, "\(path) is missing from a release install's answer")
            #expect(sourceShape[path] != nil, "\(path) is missing from a checkout's answer")
        }

        #expect(release.updateAvailable == source.updateAvailable)
        #expect(release.latestVersion == source.latestVersion)
        #expect(release.release?.version == source.release?.version)
        #expect(release.release?.commitsPastTag == source.release?.commitsPastTag)
        #expect(release.release?.notes == source.release?.notes)
        #expect(release.changes.count == 2 && source.changes.count == 1)
        #expect(release.manager == source.manager)
        #expect(release.canUpdate == source.canUpdate)
        #expect(release.phase == source.phase)
        #expect(release.running == source.running)
        #expect(release.remote?.checked == source.remote?.checked)
        #expect(release.remote?.ok == source.remote?.ok)
        #expect(release.automation?.enabled == source.automation?.enabled)
    }

    @Test func aCheckoutKeepsItsOwnPathEvenWhenARecordSaysRelease() async throws {
        let world = ReleaseWorld.shared
        let scenario = "keeps-\(UUID().uuidString.prefix(8))"
        #expect(world.publish(scenario, version: "1.1.0", changelog: secondChangelog))
        let (installed, _) = ReleaseMachine.install(from: world.base(scenario))
        let asked = world.requests(for: scenario).count
        let checkout = try sourceCheckout()
        let service = installed.service(source: checkout.path)
        let status = await service.status(fetchingNow: true)
        #expect(status.source == checkout.path)
        #expect(status.remote?.ref == "origin/master")
        #expect(status.toolchain != nil)
        #expect(world.requests(for: scenario).count == asked)
    }

    @Test func aBridgeWithNeitherACheckoutNorARecordStillSaysItCannotUpdate() async throws {
        let state = makeTemporaryDirectory("neither")
        let service = UpdateService(
            stateDirectory: state, deriveSource: false,
            hooks: UpdateHooks(manager: { "systemd" }, stamp: { nil }, terminate: {}, home: state.path))
        let status = await service.status(fetchingNow: true)
        #expect(!status.canUpdate)
        #expect(status.obstacle?.kind == "noCheckout")
        #expect(status.remote?.checked == false)
    }
}
