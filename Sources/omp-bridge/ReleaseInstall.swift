import Crypto
import Foundation

struct ReleaseInstall: Equatable, Sendable {
    let repo: String
    let base: URL

    static func read(stateDirectory: URL) -> ReleaseInstall? {
        struct Record: Decodable {
            var mode: String?
            var repo: String?
            var base: String?
        }
        guard let data = try? Data(contentsOf: stateDirectory.appendingPathComponent("install.json")),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.mode == "release", let text = record.base, let base = trustedBase(text)
        else { return nil }
        return ReleaseInstall(repo: record.repo ?? "", base: base)
    }

    static func trustedBase(_ text: String) -> URL? {
        let trimmed = text.hasSuffix("/") ? String(text.dropLast()) : text
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased(), url.user == nil, url.query == nil, url.fragment == nil
        else { return nil }
        if scheme == "https" { return url }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host) ? url : nil
    }

    func url(_ asset: String) -> URL { base.appendingPathComponent(asset) }

    static var platform: String? {
        #if os(Linux) && arch(x86_64)
            return "linux-x86_64"
        #elseif os(Linux) && arch(arm64)
            return "linux-aarch64"
        #elseif os(macOS) && arch(arm64)
            return "darwin-arm64"
        #else
            return nil
        #endif
    }
}

struct KeptInstaller: Sendable {
    let stateDirectory: URL

    var script: URL { stateDirectory.appendingPathComponent("install.sh") }
    private var recorded: URL { stateDirectory.appendingPathComponent("install.sh.sha256") }

    enum Verdict: Equatable, Sendable {
        case verified
        case missing
        case changed
    }

    func verdict() -> Verdict {
        guard let bytes = try? Data(contentsOf: script), !bytes.isEmpty,
            let line = try? String(contentsOf: recorded, encoding: .utf8)
        else { return .missing }
        let expected = line.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
        return expected?.lowercased() == Self.digest(bytes) ? .verified : .changed
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func stage(into directory: URL) -> String? {
        guard verdict() == .verified else { return nil }
        try? FileManager.default.removeItem(at: directory)
        guard
            (try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil
        else { return nil }
        let staged = directory.appendingPathComponent("install.sh")
        guard (try? FileManager.default.copyItem(at: script, to: staged)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        return staged.path
    }
}

struct ReleaseSnapshot: Codable, Sendable, Equatable {
    var latest: String?
    var etag: String?
    var checkedAt: Date?
    var changelog: String?
    var changelogFor: String?
    var failure: String?
}

struct ReleaseFeed: Sendable {
    let install: ReleaseInstall
    let stateDirectory: URL

    static let interval: TimeInterval = 300
    static let floor: TimeInterval = 10
    static let pointerLimit = 64
    static let changelogLimit = 256 * 1024

    private var cacheURL: URL { stateDirectory.appendingPathComponent("update.release.json") }

    func cached() -> ReleaseSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONCoding.decoder.decode(ReleaseSnapshot.self, from: data)
    }

    func look(force: Bool, now: Date = Date()) -> ReleaseSnapshot {
        var snapshot = cached() ?? ReleaseSnapshot()
        let age = snapshot.checkedAt.map { now.timeIntervalSince($0) }
        if let age, snapshot.latest != nil || snapshot.failure != nil,
            age < (force ? Self.floor : Self.interval), age >= 0
        {
            return snapshot
        }
        snapshot.checkedAt = now
        snapshot.failure = nil
        let pointer = fetch("latest.txt", etag: snapshot.etag, limit: Self.pointerLimit)
        switch pointer.status {
        case 304:
            break
        case 200:
            guard let latest = Self.version(in: pointer.body) else {
                snapshot.failure = "The release list at \(install.base.absoluteString) is not readable."
                return save(snapshot)
            }
            snapshot.latest = latest
            snapshot.etag = pointer.etag
        case 404:
            snapshot.failure = "No release has been published yet."
            return save(snapshot)
        default:
            snapshot.failure =
                pointer.failure
                ?? (pointer.status > 0
                    ? "The project answered with HTTP \(pointer.status)." : "The project could not be reached.")
            return save(snapshot)
        }
        if let latest = snapshot.latest, snapshot.changelogFor != latest {
            let notes = fetch("CHANGELOG-\(latest).md", etag: nil, limit: Self.changelogLimit)
            switch notes.status {
            case 200:
                snapshot.changelog = String(data: notes.body, encoding: .utf8)
                snapshot.changelogFor = latest
            case 404:
                snapshot.changelog = nil
                snapshot.changelogFor = latest
            default:
                break
            }
        }
        return save(snapshot)
    }

    static func version(in data: Data) -> String? {
        guard data.count <= pointerLimit, let text = String(data: data, encoding: .utf8)
        else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = version.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard allowed, !version.hasPrefix("."), !version.hasSuffix("."), !version.contains(".."),
            ReleaseVersion(version) != nil
        else { return nil }
        return version
    }

    private func save(_ snapshot: ReleaseSnapshot) -> ReleaseSnapshot {
        if let data = try? JSONCoding.encoder.encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return snapshot
    }

    struct Response {
        var status = 0
        var etag: String?
        var body = Data()
        var failure: String?
    }

    private func fetch(_ asset: String, etag: String?, limit: Int) -> Response {
        guard Shell.which("curl") != nil else {
            return Response(failure: "curl is not on this machine's PATH, so it cannot look for releases.")
        }
        let scratch = stateDirectory.appendingPathComponent(".release-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: scratch.appendingPathExtension("body"))
            try? FileManager.default.removeItem(at: scratch.appendingPathExtension("head"))
        }
        let body = scratch.appendingPathExtension("body")
        let head = scratch.appendingPathExtension("head")
        let secure = install.base.scheme?.lowercased() == "https"
        var arguments = [
            "--silent", "--show-error", "--location", "--max-redirs", "5",
            "--proto", secure ? "=https" : "=http,https", "--proto-redir", secure ? "=https" : "=http,https",
            "--connect-timeout", "8", "--max-time", "15", "--max-filesize", String(limit),
            "--output", body.path, "--dump-header", head.path, "--write-out", "%{http_code}",
        ]
        if let etag, !etag.isEmpty { arguments += ["--header", "If-None-Match: \(etag)"] }
        arguments.append(install.url(asset).absoluteString)
        let complaint = Shell.runCapturingErrors("curl", arguments, timeout: 20)
        let status = Self.statusCode(head)
        var response = Response(status: status)
        if status == 0 || !complaint.isEmpty {
            response.status = 0
            response.failure = Self.reason(complaint, base: install.base)
            return response
        }
        if let data = try? Data(contentsOf: body), data.count <= limit { response.body = data }
        response.etag = Self.etag(head)
        return response
    }

    private static func reason(_ complaint: String, base: URL) -> String {
        let line = complaint.split(separator: "\n").first.map(String.init)?.trimmedOrNil()
        return "Could not reach \(base.host ?? "the project")" + (line.map { ": \(String($0.prefix(160)))" } ?? ".")
    }

    static func statusCode(_ headers: URL) -> Int {
        guard let text = try? String(contentsOf: headers, encoding: .utf8) else { return 0 }
        let statusLines = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("HTTP/") }
        return statusLines.last.flatMap { $0.split(separator: " ").dropFirst().first }
            .flatMap { Int($0) } ?? 0
    }

    static func etag(_ headers: URL) -> String? {
        guard let text = try? String(contentsOf: headers, encoding: .utf8) else { return nil }
        var found: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("HTTP/") { found = nil }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "etag" {
                found = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return found
    }
}
