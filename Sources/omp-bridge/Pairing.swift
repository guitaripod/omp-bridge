import Foundation
import PairingKit

struct TailnetReading: Equatable, Sendable {
    var state: String
    var dnsName: String?
    var addresses: [String]

    init(state: String, dnsName: String?, addresses: [String]) {
        self.state = state
        self.dnsName = dnsName
        self.addresses = addresses
    }

    init?(statusJSON data: Data) {
        struct Node: Decodable {
            var DNSName: String?
            var TailscaleIPs: [String]?
        }
        struct Status: Decodable {
            var BackendState: String?
            var TailscaleIPs: [String]?
            var SelfNode: Node?

            private enum CodingKeys: String, CodingKey {
                case BackendState, TailscaleIPs
                case SelfNode = "Self"
            }
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data),
            let state = status.BackendState
        else { return nil }
        let name = status.SelfNode?.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        self.init(
            state: state, dnsName: name?.isEmpty == false ? name : nil,
            addresses: status.SelfNode?.TailscaleIPs ?? status.TailscaleIPs ?? [])
    }

    var isRunning: Bool { state == "Running" }
}

struct PairingHostChoice: Equatable, Sendable {
    enum Source: String, Sendable {
        case magicDNS = "magicdns"
        case tailnetIPv4 = "tailnet-ipv4"
        case tailnetIPv6 = "tailnet-ipv6"
        case hostname
    }

    var host: String
    var source: Source
    var offTailnet: String?

    var onTailnet: Bool { offTailnet == nil }

    static func resolve(
        tailscaleFound: Bool, reading: TailnetReading?, hostname: String, port: Int,
        agent: PairingAgent
    ) -> PairingHostChoice? {
        func usable(_ host: String) -> Bool {
            PairingLink(host: host, port: port, agent: agent) != nil
        }
        if let reading, reading.isRunning {
            if let name = reading.dnsName, name.contains("."), usable(name) {
                return PairingHostChoice(host: name, source: .magicDNS)
            }
            let v4 = reading.addresses.first { $0.contains(".") && !$0.contains(":") && usable($0) }
            if let v4 { return PairingHostChoice(host: v4, source: .tailnetIPv4) }
            let v6 = reading.addresses.first { $0.contains(":") && usable($0) }
            if let v6 { return PairingHostChoice(host: v6, source: .tailnetIPv6) }
        }
        let name = sanitized(hostname)
        guard !name.isEmpty, usable(name) else { return nil }
        return PairingHostChoice(
            host: name, source: .hostname,
            offTailnet: offTailnetReason(tailscaleFound: tailscaleFound, reading: reading))
    }

    static func offTailnetReason(tailscaleFound: Bool, reading: TailnetReading?) -> String {
        guard tailscaleFound else { return "Tailscale is not installed on this computer." }
        guard let reading else { return "Tailscale is installed but is not running." }
        switch reading.state {
        case "NeedsLogin", "NeedsMachineAuth": return "Tailscale is installed but not signed in."
        case "Stopped": return "Tailscale is installed but turned off."
        case "Running": return "Tailscale is running but has not given this computer a name or an address."
        default: return "Tailscale is installed but not running."
        }
    }

    static func sanitized(_ hostname: String) -> String {
        let short = hostname.split(separator: ".").first.map(String.init) ?? hostname
        let kept = short.lowercased().unicodeScalars.map { scalar -> Character in
            let ok = (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            return ok ? Character(scalar) : "-"
        }
        return String(kept).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func displayName(_ hostname: String) -> String {
        let short = hostname.split(separator: ".").first.map(String.init) ?? hostname
        return short.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PairingPlan: Sendable {
    var link: PairingLink
    var choice: PairingHostChoice
    var keyIncluded: Bool
    var keyNote: String
    var again: String
    var qr: QRCode?

    static let header = "Scan this with Tailscode on your phone, or paste the link into Tailscode on a computer."

    func qrText(color: Bool, environment: [String: String]) -> String? {
        qr.map { TerminalQR.render($0, environment: environment, isTerminal: color) }
    }

    func plain(color: Bool, environment: [String: String], showQR: Bool) -> String {
        var out = Self.header + "\n\n"
        if showQR, let text = qrText(color: color, environment: environment) {
            out += text + "\n"
        }
        if let reason = choice.offTailnet {
            out += Self.offTailnetNote(reason: reason, qrShown: showQR) + "\n\n"
        }
        out += "  " + link.url.absoluteString + "\n\n"
        out += keyNote + "\n\n"
        out += "Show this again any time:  \(again)\n"
        return out
    }

    static func offTailnetNote(reason: String, qrShown: Bool) -> String {
        var note =
            "This computer is not on a tailnet. \(reason) The name below only works on the network "
            + "this computer is on, so a phone away from it cannot use it. Set up Tailscale on this "
            + "computer and on your phone (https://tailscale.com/download), then run this again."
        if !qrShown { note += " To print a code for this network anyway, add --any-host." }
        return note
    }

    func json(showQR: Bool) -> String {
        struct Document: Encodable {
            var link: String
            var redacted: String
            var host: String
            var port: Int
            var agent: String
            var name: String?
            var keyIncluded: Bool
            var onTailnet: Bool
            var hostSource: String
            var notes: [String]
            var again: String
            var qr: [String]?
        }
        var notes = [keyNote]
        if let reason = choice.offTailnet { notes.insert(Self.offTailnetNote(reason: reason, qrShown: showQR), at: 0) }
        let lines = showQR ? qr.map { TerminalQR.blocks($0).split(separator: "\n").map(String.init) } : nil
        let document = Document(
            link: link.url.absoluteString, redacted: link.redacted, host: link.host, port: link.port,
            agent: link.agent.rawValue, name: link.name, keyIncluded: link.key != nil,
            onTailnet: choice.onTailnet, hostSource: choice.source.rawValue, notes: notes,
            again: again, qr: lines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(document), encoding: .utf8)) ?? "{}"
    }
}

struct PairingOptions: Equatable, Sendable {
    enum Color: String, Sendable { case auto, always, never }

    var linkOnly = false
    var json = false
    var anyHost = false
    var color = Color.auto

    static let usage = "usage: pair [--link-only | --json] [--any-host] [--color auto|always|never]"

    static func parse(_ arguments: [String]) -> PairingOptions? {
        var options = PairingOptions()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--link-only": options.linkOnly = true
            case "--json": options.json = true
            case "--any-host": options.anyHost = true
            case "--color":
                guard let value = rest.popFirst(), let color = Color(rawValue: value) else { return nil }
                options.color = color
            default: return nil
            }
        }
        return options.linkOnly && options.json ? nil : options
    }
}

enum PairingConfigFile {
    static func values(at path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { continue }
            let name = String(line[..<equals])
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var value = String(line[line.index(after: equals)...])
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            values[name] = value
        }
        return values
    }
}

struct PairingContext: Sendable {
    var environment: [String: String]
    var home: String
    var hostname: String
    var tailscaleCandidates: [String]
    var isTerminal: Bool
    var executable: String
    var workingDirectory: String

    static let knownTailscalePaths = [
        "/usr/bin/tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    static var live: PairingContext {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        let hostname = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let environment = ProcessInfo.processInfo.environment
        return PairingContext(
            environment: environment,
            home: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            hostname: hostname, tailscaleCandidates: knownTailscalePaths,
            isTerminal: isatty(STDOUT_FILENO) != 0, executable: CommandLine.arguments.first ?? "",
            workingDirectory: FileManager.default.currentDirectoryPath)
    }

    func value(_ name: String, file: [String: String]) -> String? {
        if let value = environment[name], !value.isEmpty { return value }
        return file[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    func anyTailscale(override: String?) -> String? {
        var candidates = tailscaleCandidates
        if let override, !override.isEmpty { candidates.insert(override, at: 0) }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return onPath("tailscale")
    }

    func onPath(_ name: String) -> String? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func reading(cli: String?) -> TailnetReading? {
        guard let cli else { return nil }
        return TailnetReading(statusJSON: Shell.data(cli, ["status", "--json"], timeout: 5))
    }

    func invocation(program: String) -> String {
        var path = executable
        if path.isEmpty { return "\(program) pair" }
        if !path.contains("/") {
            path = onPath(path) ?? program
            if !path.contains("/") { return "\(path) pair" }
        } else if !path.hasPrefix("/") {
            path = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workingDirectory))
                .standardizedFileURL.path
        }
        if path.contains(" ") { return "'\(path)' pair" }
        if !home.isEmpty, path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        return "\(path) pair"
    }
}
