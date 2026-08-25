import Foundation

enum OmpVersion {
    static let fallback = "0.1.0"

    static func describe(source: String?) -> String {
        guard let source,
            let described = Shell.run("git", ["describe", "--tags", "--always", "--dirty"], cwd: source)
                .trimmedOrNil()
        else { return fallback }
        return described
    }

    static func commit(source: String?) -> String? {
        guard let source else { return nil }
        return Shell.run("git", ["rev-parse", "--short", "HEAD"], cwd: source).trimmedOrNil()
    }

    static func sourceDirectory() -> String? {
        if let configured = ProcessInfo.processInfo.environment["OMP_SRC"], !configured.isEmpty {
            return isCheckout(configured) ? configured : nil
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            if isCheckout(directory.path) { return directory.path }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }

    private static func isCheckout(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(path)/Package.swift")
            && FileManager.default.fileExists(atPath: "\(path)/.git")
    }

    struct Stamp: Decodable {
        let version: String
        let commit: String?
        let builtAt: Date?
        let source: String?
    }

    static let running: Stamp? = {
        let environment = ProcessInfo.processInfo.environment
        let directory =
            environment["OMP_STATE_DIR"]
            ?? environment["OMP_STORE"].map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".omp-bridge").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(directory)/build.json")),
            let stamp = try? JSONCoding.decoder.decode(Stamp.self, from: data)
        else { return nil }
        return describesThisBinary(stamp) ? stamp : nil
    }()

    private static func describesThisBinary(_ stamp: Stamp) -> Bool {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let modified = executable.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        return stampDescribes(builtAt: stamp.builtAt, executableModified: modified ?? nil)
    }

    static let stampSlack: TimeInterval = 60

    static func stampDescribes(builtAt: Date?, executableModified: Date?) -> Bool {
        guard let builtAt, let executableModified else { return true }
        return executableModified <= builtAt.addingTimeInterval(stampSlack)
    }
}

enum Shell {
    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    @discardableResult
    static func run(
        _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 30
    ) -> String {
        String(
            data: data(executable, arguments, cwd: cwd, timeout: timeout), encoding: .utf8) ?? ""
    }

    static func runCapturingErrors(
        _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 30
    ) -> String {
        guard let url = which(executable) else { return "\(executable) is not on the PATH" }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        guard (try? process.run()) != nil else { return "could not run \(executable)" }
        let output = Output()
        let handle = pipe.fileHandleForReading
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = handle.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            return "timed out after \(Int(timeout))s"
        }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return "" }
        return String(data: output.data, encoding: .utf8) ?? ""
    }

    static func data(
        _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 30
    ) -> Data {
        guard let url = which(executable) else { return Data() }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        guard (try? process.run()) != nil else { return Data() }
        let output = Output()
        let handle = pipe.fileHandleForReading
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = handle.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        process.waitUntilExit()
        return output.data
    }

    static func spawn(_ executable: String, _ arguments: [String], environment: [String: String]) {
        guard let url = which(executable) else { return }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        try? process.run()
    }

    static func which(_ executable: String) -> URL? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable)
                ? URL(fileURLWithPath: executable) : nil
        }
        let path =
            ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

extension String {
    func trimmedOrNil() -> String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

enum OmpToolchain {
    static let candidates = [
        "\(NSHomeDirectory())/.local/share/swiftly/bin",
        "/usr/local/swift/usr/bin",
        "/opt/swift/usr/bin",
    ]

    static func resolve() -> String? {
        if let onPath = Shell.which("swift") { return onPath.path }
        for directory in candidates {
            let candidate = "\(directory)/swift"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func describe(_ path: String) -> String? {
        guard
            let first = Shell.run(path, ["--version"], timeout: 20)
                .split(separator: "\n").first.map(String.init)?.trimmedOrNil()
        else { return path }
        return "\(first) · \(path)"
    }
}

struct RemoteCheck: Codable, Sendable {
    var checked: Bool
    var ok: Bool
    var at: Date?
    var error: String?
    var ref: String?
}

struct UpdateObstacle: Codable, Sendable {
    var kind: String
    var summary: String
    var items: [String]
    var more: Int

    static let itemLimit = 8

    init(kind: String, summary: String, items: [String] = []) {
        self.kind = kind
        self.summary = summary
        self.items = Array(items.prefix(Self.itemLimit))
        more = max(0, items.count - Self.itemLimit)
    }
}

struct UpdateAutomation: Codable, Sendable {
    var enabled: Bool
    var lastTakenAt: Date?
    var lastTarget: String?
    var nextLookAt: Date?
    var holdingOff: String?
}

struct UpdateStatus: Codable, Sendable {
    var version: String
    var running: String?
    var restartRequired = false
    var builtAt: Date?
    var remote: RemoteCheck?
    var ahead: Int?
    var commit: String?
    var latestVersion: String?
    var latestCommit: String?
    var updateAvailable = false
    var behind: Int?
    var changes: [String] = []
    var canUpdate = false
    var reason: String?
    var manager: String
    var source: String?
    var phase: String
    var startedAt: Date?
    var finishedAt: Date?
    var log: String?
    var obstacle: UpdateObstacle?
    var busy: MachineQuiet?
    var waitingSince: Date?
    var canRestart = false
    var automation: UpdateAutomation?
    var toolchain: String?
}

struct UpdateState: Codable, Sendable {
    var phase: String
    var startedAt: Date?
    var finishedAt: Date?
    var pid: Int32?
}

struct UpdatePolicy: Codable, Sendable {
    var enabled = false
    var lastTakenAt: Date?
    var lastTarget: String?
    var failedTarget: String?
    var failures = 0
    var retryAfter: Date?

    static let firstBackoff: TimeInterval = 3600
    static let maximumBackoff: TimeInterval = 24 * 3600

    static func key(_ commit: String) -> String { String(commit.prefix(7)) }

    mutating func noteFailure(target: String, now: Date = Date()) {
        let target = Self.key(target)
        failures = failedTarget == target ? failures + 1 : 1
        failedTarget = target
        let delay = min(
            Self.maximumBackoff, Self.firstBackoff * pow(2, Double(min(failures - 1, 8))))
        retryAfter = now.addingTimeInterval(delay)
    }

    mutating func noteSuccess(target: String?, now: Date = Date()) {
        lastTakenAt = now
        lastTarget = target.map(Self.key)
        failedTarget = nil
        failures = 0
        retryAfter = nil
    }

    func allows(target: String, now: Date = Date()) -> Bool {
        guard failedTarget == Self.key(target), let retryAfter else { return true }
        return now >= retryAfter
    }
}

actor UpdateService {
    private let source: String?
    private let stateDirectory: URL
    private let stateURL: URL
    private let logURL: URL
    private let policyURL: URL
    private var policy: UpdatePolicy
    private var lastFetch: Date?
    private var cachedRemote: RemoteState?
    private var waitingSince: Date?
    private var barrier: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    private var quiet: (@Sendable () async -> MachineQuiet)?
    private var settle: (@Sendable () async -> Void)?

    private struct RemoteState {
        let commit: String
        let describe: String?
        let changes: [String]
        let behind: Int
        let ahead: Int
        let aheadSubjects: [String]
        let ref: String?
        let at: Date
        let fetchFailed: String?
    }

    private var lastRemoteError: String?

    init(stateDirectory: URL, sourceOverride: String? = nil) {
        source = sourceOverride ?? OmpVersion.sourceDirectory()
        self.stateDirectory = stateDirectory
        stateURL = stateDirectory.appendingPathComponent("update.state.json")
        logURL = stateDirectory.appendingPathComponent("update.log")
        policyURL = stateDirectory.appendingPathComponent("update.policy.json")
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        policy =
            (try? Data(contentsOf: policyURL)).flatMap {
                try? JSONCoding.decoder.decode(UpdatePolicy.self, from: $0)
            } ?? UpdatePolicy()
    }

    func attach(
        quiet: @escaping @Sendable () async -> MachineQuiet,
        settle: (@Sendable () async -> Void)? = nil
    ) {
        self.quiet = quiet
        self.settle = settle
    }

    func status(refreshing: Bool = true) async -> UpdateStatus {
        var status = await read(refreshing: refreshing)
        status.automation = automation(
            manager: status.manager, blocked: status.canUpdate ? nil : status.reason,
            owed: status.restartRequired && !status.canRestart)
        return status
    }

    private func read(refreshing: Bool) async -> UpdateStatus {
        let state = readState()
        let phase = settled(state)
        let checkout = OmpVersion.describe(source: source)
        let manager = Self.serviceManager()
        let busy = await quiet?() ?? .unknown
        let owed = restartRequired(source: source)
        var status = UpdateStatus(
            version: checkout,
            running: OmpVersion.running?.version,
            restartRequired: owed,
            builtAt: OmpVersion.running?.builtAt,
            remote: RemoteCheck(checked: false, ok: false),
            commit: OmpVersion.commit(source: source),
            manager: manager,
            source: source,
            phase: phase,
            startedAt: state?.startedAt,
            finishedAt: state?.finishedAt,
            log: phase == "idle" ? nil : logTail(),
            busy: busy,
            waitingSince: waitingSince,
            canRestart: owed && manager != "manual")
        guard let source else {
            status.reason =
                "This bridge was not installed from a git checkout, so it cannot update itself."
            status.obstacle = UpdateObstacle(
                kind: "noCheckout", summary: "There is no checkout on that machine to update from.")
            status.remote = RemoteCheck(
                checked: false, ok: false,
                error: "There is no checkout here to compare against the project.")
            return status
        }
        guard Shell.which("git") != nil else {
            status.reason = "git is needed to update, and it is not on this machine's PATH."
            status.obstacle = UpdateObstacle(
                kind: "noGit", summary: "git is not on that machine's PATH.")
            status.remote = RemoteCheck(
                checked: false, ok: false, error: "git is not on this machine's PATH.")
            return status
        }
        if let toolchain = OmpToolchain.resolve() {
            status.toolchain = OmpToolchain.describe(toolchain)
            if let obstacle = dirt(source) {
                status.reason = obstacle.summary
                status.obstacle = obstacle
            } else {
                status.canUpdate = true
                if manager == "manual" {
                    status.reason =
                        "No service supervises this bridge, so it will rebuild but you will have "
                        + "to start it again yourself."
                }
            }
        } else {
            status.reason =
                "A Swift toolchain is needed to rebuild, and none was found on that machine."
            status.obstacle = UpdateObstacle(
                kind: "noToolchain",
                summary: "No Swift toolchain on that machine, so nothing there can rebuild.",
                items: OmpToolchain.candidates)
        }
        guard refreshing else {
            status.remote = RemoteCheck(
                checked: false, ok: false, error: "This answer did not consult the project.")
            return status
        }
        guard let remote = remoteState() else {
            status.remote = RemoteCheck(
                checked: true, ok: false, at: Date(),
                error: lastRemoteError ?? "The project could not be reached.")
            return status
        }
        status.latestCommit = remote.commit
        status.latestVersion = remote.describe
        status.changes = remote.changes
        status.behind = remote.behind
        status.ahead = remote.ahead
        status.updateAvailable = remote.behind > 0
        status.remote = RemoteCheck(
            checked: true, ok: remote.fetchFailed == nil, at: remote.at,
            error: remote.fetchFailed, ref: remote.ref)
        if remote.ahead > 0 {
            status.canUpdate = false
            let summary =
                "That checkout has \(remote.ahead) commits of its own, so it cannot be "
                + "fast-forwarded onto the project."
            status.reason = summary
            status.obstacle = UpdateObstacle(
                kind: "ahead", summary: summary, items: remote.aheadSubjects)
        }
        return status
    }

    private func automation(manager: String, blocked: String?, owed: Bool) -> UpdateAutomation {
        UpdateAutomation(
            enabled: policy.enabled, lastTakenAt: policy.lastTakenAt,
            lastTarget: policy.lastTarget,
            nextLookAt: policy.enabled ? Date().addingTimeInterval(Self.lookEvery) : nil,
            holdingOff: policy.enabled
                ? holdingOff(manager: manager, blocked: blocked, owed: owed) : nil)
    }

    private func holdingOff(manager: String, blocked: String?, owed: Bool) -> String? {
        if manager == "manual" {
            return "Nothing supervises this bridge, so it will not replace itself unattended."
        }
        if owed {
            return "A build is waiting on that machine and nothing there would start it again."
        }
        if let blocked { return blocked }
        guard let failed = policy.failedTarget, let retry = policy.retryAfter, retry > Date() else {
            return nil
        }
        return
            "Held off after \(policy.failures) failed attempts at \(failed). A newer commit, or an "
            + "update taken by hand, clears it."
    }

    private func installerAlive() -> Bool {
        guard let state = readState(), Self.installing.contains(state.phase),
            let pid = state.pid, pid > 0
        else { return false }
        return kill(pid, 0) == 0
    }

    private static let installing: Set<String> = ["running", "building"]

    private func settled(_ state: UpdateState?) -> String {
        guard let state else { return "idle" }
        let unfinished = ["running", "building", "restarting", "waiting"].contains(state.phase)
        guard unfinished else { return terminal(state) }
        if state.phase == "waiting" { return waitingSince == nil ? "failed" : "waiting" }
        if state.phase == "restarting" { return aged(state) ? "succeeded" : state.phase }
        if installerAlive() { return state.phase }
        guard state.pid != nil || aged(state, over: 120) else { return state.phase }
        return "failed"
    }

    private func aged(_ state: UpdateState, over: TimeInterval = 6 * 3600) -> Bool {
        guard let started = state.startedAt else { return true }
        return Date().timeIntervalSince(started) > over
    }

    private func terminal(_ state: UpdateState) -> String {
        guard state.phase == "failed", let built = OmpVersion.running?.builtAt,
            let finished = state.finishedAt, finished < built
        else { return state.phase }
        return "idle"
    }

    func start() async -> (accepted: Bool, status: UpdateStatus) {
        var current = await status(refreshing: false)
        guard current.canUpdate else { return (false, current) }
        guard !installerAlive(), current.phase != "restarting", current.phase != "waiting" else {
            return (false, current)
        }
        guard let source, let script = stagedScript(source: source) else {
            current.reason = "install.sh is missing from the checkout, so there is nothing to run."
            return (false, current)
        }
        try? Data().write(to: logURL, options: .atomic)
        write(UpdateState(phase: "running", startedAt: Date(), finishedAt: nil, pid: nil))
        detach(script: script, source: source)
        watch()
        lastFetch = nil
        return (true, await status(refreshing: false))
    }

    func restart() async -> (accepted: Bool, status: UpdateStatus) {
        var current = await status(refreshing: false)
        guard Self.serviceManager() != "manual" else {
            current.reason =
                "Nothing supervises this bridge, so it would not come back. Start it on that "
                + "machine instead."
            return (false, current)
        }
        guard current.restartRequired || current.phase == "restarting" else {
            current.reason = "This bridge is already running the build in its checkout."
            return (false, current)
        }
        guard barrier == nil else { return (true, current) }
        beginRestart()
        return (true, await status(refreshing: false))
    }

    func setAutomation(enabled: Bool) async -> UpdateStatus {
        policy.enabled = enabled
        writePolicy()
        return await status(refreshing: true)
    }

    private func detach(script: String, source: String) {
        var environment = [
            "OMP_SRC": source,
            "OMP_STATE_DIR": stateDirectory.path,
        ]
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        if let toolchain = OmpToolchain.resolve() { environment["OMP_SWIFT"] = toolchain }
        Shell.spawn("/bin/bash", [script, "--update", "--managed"], environment: environment)
    }

    func resume() {
        guard let state = readState() else { return }
        switch state.phase {
        case "restarting", "waiting":
            policy.noteSuccess(target: OmpVersion.running?.commit)
            writePolicy()
            write(
                UpdateState(
                    phase: "succeeded", startedAt: state.startedAt, finishedAt: Date(), pid: nil))
        case "running", "building":
            watch()
        default:
            break
        }
    }

    private func watch() {
        Task { [weak self] in
            guard let self else { return }
            while true {
                try? await Task.sleep(for: .seconds(2))
                let phase = await self.phaseOnDisk()
                if phase == "restarting" {
                    await self.beginRestart()
                    return
                }
                if phase == "failed" {
                    await self.noteFailedAttempt()
                    return
                }
                if phase == "succeeded" || phase == nil { return }
                if await self.installerAlive() == false {
                    if await self.restartOwed() {
                        await self.beginRestart()
                    } else {
                        await self.markFailed()
                    }
                    return
                }
            }
        }
    }

    private func phaseOnDisk() -> String? { readState()?.phase }

    private func restartOwed() -> Bool { restartRequired(source: source) }

    private func markFailed() {
        write(
            UpdateState(
                phase: "failed", startedAt: readState()?.startedAt, finishedAt: Date(), pid: nil))
        noteFailedAttempt()
    }

    private func noteFailedAttempt() {
        let target = cachedRemote?.commit ?? remoteHead(source ?? "") ?? "unknown"
        policy.noteFailure(target: UpdatePolicy.key(target))
        writePolicy()
    }

    private func beginRestart() {
        guard barrier == nil else { return }
        guard Self.serviceManager() != "manual" else {
            write(
                UpdateState(
                    phase: "succeeded", startedAt: readState()?.startedAt, finishedAt: Date(),
                    pid: nil))
            return
        }
        waitingSince = Date()
        write(
            UpdateState(
                phase: "waiting", startedAt: readState()?.startedAt, finishedAt: nil, pid: nil))
        barrier = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.quietDeadline)
            while Date() < deadline {
                if await self.machineIsQuiet() {
                    await self.finishAndExit()
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
            await self.abandonRestart()
        }
    }

    private func machineIsQuiet() async -> Bool {
        guard let quiet else { return false }
        guard await quiet().quiet else { return false }
        try? await Task.sleep(for: .seconds(1))
        return await quiet().quiet
    }

    private func abandonRestart() {
        barrier = nil
        waitingSince = nil
        write(
            UpdateState(
                phase: "succeeded", startedAt: readState()?.startedAt, finishedAt: Date(), pid: nil))
    }

    private func finishAndExit() async {
        write(
            UpdateState(
                phase: "restarting", startedAt: readState()?.startedAt, finishedAt: Date(),
                pid: nil))
        policy.noteSuccess(target: OmpVersion.commit(source: source))
        writePolicy()
        await settle?()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)
    }

    func startAutomation() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            while !Task.isCancelled {
                await self?.considerUpdating()
                try? await Task.sleep(for: .seconds(Self.lookEvery))
            }
        }
    }

    private func considerUpdating() async {
        guard policy.enabled, Self.serviceManager() != "manual", !installerAlive(),
            barrier == nil
        else { return }
        let current = await status(refreshing: true)
        if current.restartRequired, current.canRestart {
            beginRestart()
            return
        }
        guard current.canUpdate, current.updateAvailable, current.remote?.ok == true,
            let target = current.latestCommit, policy.allows(target: target)
        else { return }
        _ = await start()
    }

    private func stagedScript(source: String) -> String? {
        let directory = stateDirectory.appendingPathComponent("staging")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent("install.sh").path
        if let head = remoteHead(source) {
            let script = Shell.run("git", ["show", "\(head):install.sh"], cwd: source)
            if script.contains("#!"), write(script, to: staged) { return staged }
        }
        let local = "\(source)/install.sh"
        guard let script = try? String(contentsOfFile: local, encoding: .utf8),
            write(script, to: staged)
        else { return nil }
        return staged
    }

    private func write(_ script: String, to path: String) -> Bool {
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return true
    }

    private func remoteState() -> RemoteState? {
        guard let source else {
            lastRemoteError = "There is no checkout here to compare against the project."
            return nil
        }
        if lastFetch.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
            let complaint = Shell.runCapturingErrors(
                "git", ["fetch", "--quiet", "--tags", "origin"], cwd: source, timeout: 25)
            lastFetch = Date()
            lastRemoteError = complaint.trimmedOrNil().map {
                "Could not reach the project: \(String($0.prefix(200)))"
            }
        }
        guard let upstream = remoteRef(source), let head = remoteHead(source) else {
            lastRemoteError =
                lastRemoteError ?? "This checkout tracks nothing that could be compared against."
            return nil
        }
        let behind =
            Int(
                Shell.run("git", ["rev-list", "--count", "HEAD..\(head)"], cwd: source)
                    .trimmedOrNil() ?? "")
        let ahead =
            Int(
                Shell.run("git", ["rev-list", "--count", "\(head)..HEAD"], cwd: source)
                    .trimmedOrNil() ?? "")
        guard let behind, let ahead else {
            lastRemoteError = "git could not count how far this checkout is from the project."
            return nil
        }
        let changes = Shell.run(
            "git", ["log", "--pretty=format:%s", "-20", "HEAD..\(head)"], cwd: source
        ).split(separator: "\n").map(String.init)
        let mine =
            ahead > 0
            ? Shell.run(
                "git", ["log", "--pretty=format:%s", "-20", "\(head)..HEAD"], cwd: source
            ).split(separator: "\n").map(String.init) : []
        let describe = Shell.run("git", ["describe", "--tags", "--always", head], cwd: source)
            .trimmedOrNil()
        let state = RemoteState(
            commit: String(head.prefix(7)), describe: describe, changes: changes, behind: behind,
            ahead: ahead, aheadSubjects: mine, ref: upstream, at: Date(),
            fetchFailed: lastRemoteError)
        cachedRemote = state
        return state
    }

    private func remoteRef(_ source: String) -> String? {
        if let upstream = Shell.run(
            "git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: source
        ).trimmedOrNil() {
            return upstream
        }
        for candidate in ["origin/HEAD", "origin/master", "origin/main"]
        where Shell.run("git", ["rev-parse", candidate], cwd: source).trimmedOrNil() != nil {
            return candidate
        }
        return nil
    }

    private func remoteHead(_ source: String) -> String? {
        guard !source.isEmpty else { return nil }
        if let upstream = Shell.run(
            "git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: source
        ).trimmedOrNil() {
            return Shell.run("git", ["rev-parse", upstream], cwd: source).trimmedOrNil()
        }
        for candidate in ["origin/HEAD", "origin/master", "origin/main"] {
            if let resolved = Shell.run("git", ["rev-parse", candidate], cwd: source).trimmedOrNil()
            {
                return resolved
            }
        }
        return nil
    }

    private func dirt(_ source: String) -> UpdateObstacle? {
        let porcelain = Shell.run("git", ["status", "--porcelain"], cwd: source)
            .split(separator: "\n").map(String.init)
        guard !porcelain.isEmpty else { return nil }
        let untracked = porcelain.filter { $0.hasPrefix("??") }
        let changed = porcelain.filter { !$0.hasPrefix("??") }
        let summary =
            changed.isEmpty
            ? "The checkout at \(source) has \(untracked.count) untracked files, and the installer "
                + "refuses to build a tree it did not expect."
            : "The checkout at \(source) has \(changed.count) uncommitted changes"
                + (untracked.isEmpty ? "." : " and \(untracked.count) untracked files.")
        return UpdateObstacle(
            kind: "dirty", summary: summary,
            items: (changed + untracked).map { String($0.dropFirst(3)) })
    }

    private func restartRequired(source: String?) -> Bool {
        guard let source, dirt(source) == nil else { return false }
        guard let built = OmpVersion.running?.commit, !built.isEmpty,
            let head = OmpVersion.commit(source: source)
        else { return false }
        return !built.hasPrefix(head) && !head.hasPrefix(built)
    }

    private func readState() -> UpdateState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONCoding.decoder.decode(UpdateState.self, from: data)
    }

    private func write(_ state: UpdateState) {
        var state = state
        if state.pid == nil, Self.installing.contains(state.phase) {
            state.pid = readState()?.pid
        }
        guard let data = try? JSONCoding.encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func writePolicy() {
        guard let data = try? JSONCoding.encoder.encode(policy) else { return }
        try? data.write(to: policyURL, options: .atomic)
    }

    private func logTail(lines: Int = 12, characters: Int = 2000) -> String? {
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let tail = contents.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return String(tail.suffix(characters)).trimmedOrNil()
    }

    private static let lookEvery: TimeInterval = 30 * 60
    private static let quietDeadline: TimeInterval = 12 * 3600

    static func serviceManager() -> String {
        #if os(macOS)
            return Shell.run("launchctl", ["list"], timeout: 10)
                .contains("com.omp.bridge") ? "launchd" : "manual"
        #else
            guard let unit = systemdUnit() else { return "manual" }
            let restart = Shell.run(
                "systemctl", ["--user", "show", unit, "-p", "Restart", "--value"], timeout: 10
            ).trimmedOrNil()
            return restart == "always" || restart == "on-success" ? "systemd" : "manual"
        #endif
    }

    private static func systemdUnit() -> String? {
        guard let cgroup = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8) else {
            return nil
        }
        for line in cgroup.split(separator: "\n") {
            let units = line.split(separator: "/").filter { $0.hasSuffix(".service") }
            if let unit = units.last, !unit.hasPrefix("user@") { return String(unit) }
        }
        return nil
    }
}
