import Foundation
import Testing

@testable import omp_bridge

enum Repository {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func script(_ name: String) -> String { root.appendingPathComponent(name).path }
}

struct Ran {
    var status: Int32
    var output: String
}

func run(
    _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
    in directory: URL? = nil
) -> Ran {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = directory }
    let capture = FileManager.default.temporaryDirectory
        .appendingPathComponent("run-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: capture.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: capture) }
    guard let sink = try? FileHandle(forWritingTo: capture) else { return Ran(status: 127, output: "") }
    process.standardOutput = sink
    process.standardError = sink
    process.standardInput = FileHandle.nullDevice
    var launched = false
    var launchError = ""
    for _ in 0..<5 where !launched {
        do {
            try process.run()
            launched = true
        } catch {
            launchError = "\(error)"
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
    guard launched else { return Ran(status: 127, output: "could not launch \(executable): \(launchError)") }
    process.waitUntilExit()
    try? sink.close()
    let output = (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
    return Ran(status: process.terminationStatus, output: output)
}

func makeTemporaryDirectory(_ name: String = "bridge-test") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class ReleaseWorld: @unchecked Sendable {
    static let shared = ReleaseWorld()

    let root = makeTemporaryDirectory("release-world")
    let www: URL
    let log: URL
    let port: Int
    let tools: URL
    private let process = Process()

    private init() {
        www = root.appendingPathComponent("www")
        log = root.appendingPathComponent("requests.log")
        tools = root.appendingPathComponent("tools")
        try? FileManager.default.createDirectory(at: www, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for tool in [
            "uname", "date", "mkdir", "mktemp", "curl", "tar", "awk", "sed", "head", "tr", "cut", "base64",
            "df", "sha256sum", "shasum", "grep", "cat", "chmod", "mv", "cp", "rm", "touch", "find",
            "dirname", "sleep", "hostname", "id", "tail", "ls", "strip", "stat", "gzip", "bash", "sh",
            "env", "wc",
        ] {
            if let found = Shell.which(tool) {
                try? FileManager.default.createSymbolicLink(
                    at: tools.appendingPathComponent(tool), withDestinationURL: found)
            }
        }
        let portFile = root.appendingPathComponent("port")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-I", Repository.script("scripts/fake-release-server.py"), "--dir", www.path,
            "--port-file", portFile.path, "--log", log.path, "--parent",
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        var found = 0
        for _ in 0..<100 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let number = Int(text) {
                found = number
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        port = found
    }

    func base(_ scenario: String) -> String { "http://127.0.0.1:\(port)/\(scenario)" }

    var closedBase: String {
        let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(socketFD, $0, length)
                _ = getsockname(socketFD, $0, &length)
            }
        }
        let closed = Int(UInt16(bigEndian: address.sin_port))
        close(socketFD)
        return "http://127.0.0.1:\(closed)/nothing"
    }

    func requests(for scenario: String) -> [String] {
        let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
        return lines.map(String.init).filter { $0.hasPrefix("/\(scenario)/") }
    }

    static func changelog(_ versions: [(String, [String])]) -> String {
        "# Changelog\n\n"
            + versions.map { version, items in
                "## \(version) — 2026-10-01\n\n" + items.map { "- \($0)\n" }.joined()
            }.joined(separator: "\n")
    }

    @discardableResult
    func publish(
        _ scenario: String, version: String, changelog: String, pointer: String? = nil
    ) -> Bool {
        let directory = www.appendingPathComponent(scenario)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = makeTemporaryDirectory("publish")
        defer { try? FileManager.default.removeItem(at: work) }
        let program = work.appendingPathComponent("omp-bridge")
        try? "#!/bin/sh\ncase \"${1:-}\" in --version) echo \"omp-bridge \(version)\" ;; esac\n"
            .write(to: program, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let notes = work.appendingPathComponent("CHANGELOG.md")
        try? changelog.write(to: notes, atomically: true, encoding: .utf8)
        var packaged = Ran(status: 1, output: "")
        for _ in 0..<8 {
            packaged = run(
                Repository.script("scripts/package-release.sh"),
                [
                    "--binary", program.path, "--version", version, "--changelog", notes.path,
                    "--out", directory.path,
                ])
            if packaged.status == 0 || !packaged.output.contains("Text file busy") { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if packaged.status != 0 { print("PACKAGE FAILED", packaged.status, packaged.output) }
        try? ((pointer ?? version) + "\n").write(
            to: directory.appendingPathComponent("latest.txt"), atomically: true, encoding: .utf8)
        return packaged.status == 0
    }

    func spoilChecksum(_ scenario: String, version: String) {
        for file in (try? FileManager.default.contentsOfDirectory(atPath: www.appendingPathComponent(scenario).path)) ?? []
        where file.hasSuffix(".tar.gz.sha256") && file.contains(version) {
            try? String(repeating: "0", count: 64).appending("  \(file.dropLast(7))\n")
                .write(to: www.appendingPathComponent(scenario).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }
}

struct ReleaseMachine {
    let home: URL
    let state: URL
    let base: String

    static func install(from base: String, world: ReleaseWorld = .shared) -> (ReleaseMachine, Ran) {
        let home = makeTemporaryDirectory("release-machine")
        let machine = ReleaseMachine(home: home, state: home.appendingPathComponent("state"), base: base)
        let ran = run(
            "/bin/bash", [Repository.script("install.sh"), "--no-service"],
            environment: [
                "HOME": home.path, "USER": "tester", "PATH": world.tools.path,
                "OMP_STATE_DIR": machine.state.path, "OMP_RELEASE_BASE": base,
                "OMP_PORT": "1", "OMP_PASSWORD": "pw", "OMP_HEALTH_ATTEMPTS": "1",
                "OMP_TAILSCALE": home.appendingPathComponent("no-tailscale").path,
            ])
        return (machine, ran)
    }

    var program: URL { home.appendingPathComponent(".local/bin/omp-bridge") }

    var config: String? {
        try? String(
            contentsOf: home.appendingPathComponent(".config/omp-bridge.env"), encoding: .utf8)
    }

    func contents(_ name: String) -> String? {
        try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8)
    }

    func service(
        manager: String = "systemd", terminations: Counter = Counter(), source: String? = nil
    ) -> UpdateService {
        let launched = OmpVersion.onDisk(in: state)
        return UpdateService(
            stateDirectory: state, sourceOverride: source, deriveSource: false,
            hooks: UpdateHooks(
                manager: { manager }, stamp: { launched }, terminate: { terminations.bump() },
                home: home.path))
    }

    func restarted(manager: String = "systemd") -> UpdateService {
        let launched = OmpVersion.onDisk(in: state)
        return UpdateService(
            stateDirectory: state, deriveSource: false,
            hooks: UpdateHooks(
                manager: { manager }, stamp: { launched }, terminate: {}, home: home.path))
    }
}

func eventually(timeout: TimeInterval = 40, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return await condition()
}

func jsonObject<T: Encodable>(_ value: T) -> [String: Any] {
    let data = (try? JSONCoding.encoder.encode(value)) ?? Data()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}
