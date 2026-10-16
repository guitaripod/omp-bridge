import Foundation
import PairingKit
import Testing

@testable import omp_bridge

private func status(
    state: String = "Running", dns: String? = "Box.tail1234.ts.net.",
    addresses: [String] = ["100.64.0.7", "fd7a:115c:a1e0::7"]
) -> String {
    let name = dns.map { "\"DNSName\": \"\($0)\"," } ?? ""
    let list = addresses.map { "\"\($0)\"" }.joined(separator: ",")
    return """
        {"BackendState": "\(state)", "TailscaleIPs": [\(list)],
         "Self": {\(name) "UserID": 42, "TailscaleIPs": [\(list)]},
         "User": {"42": {"LoginName": "me@example.com"}}}
        """
}

private enum FakeTailscale {
    static let script: URL = {
        let url = makeTemporaryDirectory("fake-tailscale").appendingPathComponent("tailscale")
        let body = "#!/bin/sh\ncat \"$(dirname \"$0\")/status.json\"\nexit \"$(cat \"$(dirname \"$0\")/status.exit\")\"\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }()
}

private struct Machine {
    let directory = makeTemporaryDirectory("pairing")
    var hostname = "test-box.local"

    var bin: URL { directory.appendingPathComponent("bin") }
    var fake: String { bin.appendingPathComponent("tailscale").path }

    func tailscale(_ output: String, exit code: Int = 0) {
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? output.write(to: bin.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try? "\(code)".write(to: bin.appendingPathComponent("status.exit"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: fake)
        try? FileManager.default.createSymbolicLink(
            atPath: fake, withDestinationPath: FakeTailscale.script.path)
    }

    func config(_ lines: String) {
        let folder = directory.appendingPathComponent(".config")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? lines.write(to: folder.appendingPathComponent("omp-bridge.env"), atomically: true, encoding: .utf8)
    }

    func context(
        _ environment: [String: String] = [:], tty: Bool = false, found: Bool = true
    ) -> PairingContext {
        var merged = [
            "PATH": found ? bin.path : directory.appendingPathComponent("empty").path,
            "LANG": "en_US.UTF-8", "TERM": "xterm-256color",
        ]
        if found { merged["OMP_TAILSCALE"] = fake }
        merged.merge(environment) { _, new in new }
        return PairingContext(
            environment: merged, home: directory.path, hostname: hostname,
            tailscaleCandidates: [], isTerminal: tty,
            executable: directory.appendingPathComponent(".omp-bridge/bin/omp-bridge").path,
            workingDirectory: directory.path)
    }

    func pair(
        _ arguments: [String] = [], _ environment: [String: String] = [:], found: Bool = true
    ) -> PairingCommand.Outcome {
        PairingCommand.run(arguments: arguments, context: context(environment, found: found))
    }
}

private func parsedLink(_ outcome: PairingCommand.Outcome) throws -> PairingLink {
    let line = outcome.stdout.split(separator: "\n")
        .first { $0.contains("tailscode://connect") }.map { $0.trimmingCharacters(in: .whitespaces) }
    return try #require(line.flatMap { PairingLink(string: $0) })
}

@Suite struct PairingHostTests {
    @Test func theMagicDNSNameIsUsedLowercaseWithoutItsTrailingDot() throws {
        let machine = Machine()
        machine.tailscale(status())
        let link = try parsedLink(machine.pair(["--color", "never"]))
        #expect(link.host == "box.tail1234.ts.net")
        #expect(link.port == 4099)
        #expect(link.agent == .omp)
        #expect(link.name == "test-box")
        #expect(link.isTailnetAddress)
    }

    @Test func withoutAMagicDNSNameTheTailnetIPv4IsUsed() throws {
        let machine = Machine()
        machine.tailscale(status(dns: nil))
        let outcome = machine.pair(["--json"])
        let link = try parsedLink(machine.pair())
        #expect(link.host == "100.64.0.7")
        #expect(outcome.stdout.contains("\"hostSource\" : \"tailnet-ipv4\""))
    }

    @Test func aNameWithoutADotIsNotAnAddressAPhoneCanFind() throws {
        let machine = Machine()
        machine.tailscale(status(dns: "box."))
        #expect(try parsedLink(machine.pair()).host == "100.64.0.7")
    }

    @Test func aNameWithCharactersNoLinkCanCarryFallsThroughToTheAddress() throws {
        let machine = Machine()
        machine.tailscale(status(dns: "my box.tail1234.ts.net."))
        #expect(try parsedLink(machine.pair()).host == "100.64.0.7")
    }

    @Test func aTailnetThatOnlyHasIPv6IsReachedByIt() throws {
        let machine = Machine()
        machine.tailscale(status(dns: nil, addresses: ["fd7a:115c:a1e0::7"]))
        let outcome = machine.pair()
        let link = try parsedLink(outcome)
        #expect(link.host == "fd7a:115c:a1e0::7")
        #expect(link.isTailnetAddress)
        #expect(outcome.stdout.contains("host=fd7a%3A115c%3Aa1e0%3A%3A7"))
    }

    @Test(arguments: [
        ("NeedsLogin", "not signed in"), ("Stopped", "turned off"), ("Starting", "not running"),
    ])
    func aTailscaleThatIsNotUpIsNotATailnet(_ state: String, _ words: String) throws {
        let machine = Machine()
        machine.tailscale(status(state: state))
        let outcome = machine.pair()
        #expect(outcome.status == 0)
        let link = try parsedLink(outcome)
        #expect(link.host == "test-box")
        #expect(!link.isTailnetAddress)
        #expect(outcome.stdout.contains("This computer is not on a tailnet."))
        #expect(outcome.stdout.contains(words))
        #expect(outcome.stdout.contains("--any-host"))
        #expect(!outcome.stdout.contains("█") && !outcome.stdout.contains("▀"))
    }

    @Test func aTailscaleThatDoesNotAnswerIsNotATailnetEither() throws {
        let machine = Machine()
        machine.tailscale("", exit: 1)
        let outcome = machine.pair()
        #expect(try parsedLink(outcome).host == "test-box")
        #expect(outcome.stdout.contains("installed but is not running"))
    }

    @Test func noTailscaleAtAllIsSaidPlainly() throws {
        let machine = Machine()
        let outcome = machine.pair(found: false)
        #expect(try parsedLink(outcome).host == "test-box")
        #expect(outcome.stdout.contains("Tailscale is not installed on this computer."))
        #expect(!outcome.stdout.contains("█"))
    }

    @Test func aHostNameIsMadeSafeForALinkOrRefused() throws {
        var machine = Machine()
        machine.hostname = "My_Mac Studio.example.com"
        machine.tailscale("", exit: 1)
        #expect(try parsedLink(machine.pair()).host == "my-mac-studio")
        machine.hostname = "..."
        let refused = machine.pair()
        #expect(refused.status == 1)
        #expect(refused.stdout.isEmpty)
        #expect(refused.stderr.contains("cannot be used in a pairing link"))
    }

    @Test func aNonTailnetHostGetsItsCodeOnlyWhenAsked() throws {
        let machine = Machine()
        machine.tailscale(status(state: "NeedsLogin"))
        let asked = machine.pair(["--any-host", "--color", "never"])
        #expect(asked.stdout.contains("█") || asked.stdout.contains("▀"))
        #expect(!asked.stdout.contains("--any-host"))
        #expect(try parsedLink(asked).host == "test-box")
    }
}

@Suite struct PairingKeyTests {
    private func link(_ machine: Machine, _ environment: [String: String], found: Bool = true) throws -> PairingLink {
        try parsedLink(machine.pair([], environment, found: found))
    }

    @Test func theLinkCarriesThePasswordEvenOnAnUpTailnetBecauseTheBridgeChecksNoTailnet() throws {
        let machine = Machine()
        machine.tailscale(status())
        let outcome = machine.pair([], ["OMP_PASSWORD": "s3cret"])
        let found = try parsedLink(outcome)
        #expect(found.key == "s3cret")
        #expect(found.isTailnetAddress)
        #expect(outcome.stdout.contains("does not check the tailnet"))
    }

    @Test func theLinkCarriesThePasswordWithoutTailscaleToo() throws {
        let machine = Machine()
        #expect(try link(machine, ["OMP_PASSWORD": "s3cret"], found: false).key == "s3cret")
    }

    @Test func noPasswordMeansNoKey() throws {
        let machine = Machine()
        machine.tailscale(status())
        let outcome = machine.pair()
        #expect(try parsedLink(outcome).key == nil)
        #expect(outcome.stdout.contains("none is set"))
    }

    @Test func aPasswordTooLongForALinkIsLeftOutAndSaidSo() throws {
        let machine = Machine()
        machine.tailscale(status())
        let outcome = machine.pair([], ["OMP_PASSWORD": String(repeating: "x", count: 300)])
        #expect(outcome.status == 0)
        #expect(try parsedLink(outcome).key == nil)
        #expect(outcome.stdout.contains("too long to go in a link"))
    }

    @Test func thePortAndPasswordComeFromTheInstallersConfigWhenTheEnvironmentHasNone() throws {
        let machine = Machine()
        machine.tailscale(status())
        machine.config("OMP_PASSWORD=\"from file\"\nOMP_PORT=4321\nOMP_BIND=0.0.0.0\n")
        let found = try link(machine, [:])
        #expect(found.port == 4321)
        #expect(found.key == "from file")
        let overridden = try link(machine, ["OMP_PORT": "5555", "OMP_PASSWORD": "env"])
        #expect(overridden.port == 5555)
        #expect(overridden.key == "env")
    }

    @Test func aPasswordWithEveryAwkwardCharacterRoundTripsThroughTheLink() throws {
        let machine = Machine()
        machine.tailscale("", exit: 1)
        let password = "p@ss w&rd=#%/+é日本語\"'"
        let found = try link(machine, ["OMP_PASSWORD": password])
        #expect(found.key == password)
    }

    @Test func theKeyNeverReachesAnyLogLine() throws {
        let machine = Machine()
        machine.tailscale(status())
        let outcome = machine.pair([], ["OMP_PASSWORD": "s3cret"])
        let found = try parsedLink(outcome)
        #expect(found.key == "s3cret")
        #expect("\(found)".contains("s3cret") == false)
        #expect(found.redacted.contains("<redacted>"))
        #expect(outcome.stderr.isEmpty)
        let json = machine.pair(["--json"], ["OMP_PASSWORD": "s3cret"])
        let document = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect((document["redacted"] as? String)?.contains("s3cret") == false)
        #expect(document["keyIncluded"] as? Bool == true)
    }
}

@Suite struct PairingOutputTests {
    @Test func theLinkIsExactlyWhatPairingLinkParsesBack() throws {
        let machine = Machine()
        machine.tailscale(status())
        let plain = machine.pair(["--color", "never"])
        let expected = PairingLink(
            host: "box.tail1234.ts.net", port: 4099, agent: .omp, name: "test-box")
        #expect(try parsedLink(plain) == expected)
        let only = machine.pair(["--link-only"])
        #expect(only.stdout == (expected?.url.absoluteString ?? "") + "\n")
        #expect(PairingLink(string: only.stdout) == expected)
    }

    @Test func linkOnlyIsOneLineAndNothingElse() {
        let machine = Machine()
        machine.tailscale(status())
        let only = machine.pair(["--link-only"], ["OMP_PASSWORD": "x"])
        #expect(only.status == 0)
        #expect(only.stdout.split(separator: "\n").count == 1)
        #expect(only.stderr.isEmpty)
    }

    @Test func linkOnlyForAHostNobodyOutsideCanReachIsRefusedUnlessAsked() {
        let machine = Machine()
        let refused = machine.pair(["--link-only"], found: false)
        #expect(refused.status == 3)
        #expect(refused.stdout.isEmpty)
        #expect(refused.stderr.contains("not on a tailnet"))
        let asked = machine.pair(["--link-only", "--any-host"], found: false)
        #expect(asked.status == 0)
        #expect(asked.stdout.hasPrefix("tailscode://connect?v=1&host=test-box&port=4099&agent=omp&name=test-box"))
    }

    @Test func jsonIsMachineReadableAndComplete() throws {
        let machine = Machine()
        machine.tailscale(status())
        let outcome = machine.pair(["--json"])
        let document = try #require(
            try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        #expect(document["host"] as? String == "box.tail1234.ts.net")
        #expect(document["port"] as? Int == 4099)
        #expect(document["agent"] as? String == "omp")
        #expect(document["name"] as? String == "test-box")
        #expect(document["onTailnet"] as? Bool == true)
        #expect(document["keyIncluded"] as? Bool == false)
        #expect(document["hostSource"] as? String == "magicdns")
        #expect((document["again"] as? String)?.hasSuffix("omp-bridge pair") == true)
        let link = try #require((document["link"] as? String).flatMap { PairingLink(string: $0) })
        #expect(link.host == "box.tail1234.ts.net")
        let lines = try #require(document["qr"] as? [String])
        let code = try QRCode.encode(link.url.absoluteString)
        #expect(lines.count == (code.size + 2 * TerminalQR.quietZone + 1) / 2)
        #expect(lines.allSatisfy { !$0.contains("\u{1B}") })
    }

    @Test func jsonForAHostOutsideATailnetCarriesNoCodeUnlessAsked() throws {
        let machine = Machine()
        let outcome = machine.pair(["--json"], found: false)
        let document = try #require(
            try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        #expect(document["onTailnet"] as? Bool == false)
        #expect(document["qr"] == nil)
        let asked = machine.pair(["--json", "--any-host"], found: false)
        let withCode = try #require(
            try JSONSerialization.jsonObject(with: Data(asked.stdout.utf8)) as? [String: Any])
        #expect(withCode["qr"] as? [String] != nil)
    }

    @Test func theCodeHasTheLinesTheLinkNeedsAndColourOnlyWhenAsked() throws {
        let machine = Machine()
        machine.tailscale(status())
        let link = try #require(
            PairingLink(host: "box.tail1234.ts.net", port: 4099, agent: .omp, name: "test-box"))
        let code = try QRCode.encode(link.url.absoluteString)
        let expected = (code.size + 2 * TerminalQR.quietZone + 1) / 2
        let utf8 = ["LANG": "en_US.UTF-8", "TERM": "xterm-256color"]

        let plain = machine.pair(["--color", "never"], utf8)
        let block = plain.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("█") || $0.contains("▀") || $0.contains("▄") || $0.hasPrefix("  ") && $0.allSatisfy { $0 == " " } }
        #expect(block.count >= expected)
        #expect(!plain.stdout.contains("\u{1B}"))

        let colored = machine.pair(["--color", "always"], utf8)
        let ansiLines = colored.stdout.split(separator: "\n").filter { $0.contains("\u{1B}[38;5;") }
        #expect(ansiLines.count == expected)
        #expect(ansiLines.allSatisfy { $0.hasSuffix("\u{1B}[0m") })

        let ascii = machine.pair(["--color", "never"], ["LANG": "C", "TERM": "dumb"])
        #expect(ascii.stdout.contains("##"))
        let asciiRows = ascii.stdout.split(separator: "\n").filter { $0.contains("##") }
        #expect(asciiRows.count <= code.size + 2 * TerminalQR.quietZone)
    }

    @Test func aLinkTooLongToDrawIsStillPrintedAndTheMissingCodeIsExplained() throws {
        let machine = Machine()
        machine.tailscale(status())
        let password = String(repeating: "日", count: 100)
        let outcome = machine.pair(["--color", "never"], ["OMP_PASSWORD": password])
        #expect(outcome.status == 0)
        #expect(try parsedLink(outcome).key == password)
        #expect(outcome.stdout.contains("too long to draw as a code"))
        #expect(!outcome.stdout.contains("█") && !outcome.stdout.contains("▀"))
        let json = machine.pair(["--json"], ["OMP_PASSWORD": password])
        let document = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(document["qr"] == nil)
    }

    @Test func theTextSaysWhatToDoAndHowToShowItAgain() {
        let machine = Machine()
        machine.tailscale(status())
        let outcome = machine.pair(["--color", "never"])
        #expect(outcome.stdout.hasPrefix("Scan this with Tailscode on your phone, or paste the link into Tailscode on a computer.\n"))
        #expect(outcome.stdout.hasSuffix("Show this again any time:  ~/.omp-bridge/bin/omp-bridge pair\n"))
        let lines = outcome.stdout.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("  tailscode://") }.count == 1)
    }

    @Test func aPathWithASpaceIsQuotedSoItCanBePasted() {
        let machine = Machine()
        var context = machine.context()
        context.executable = "/Users/me/My Tools/omp-bridge"
        #expect(context.invocation(program: "omp-bridge") == "'/Users/me/My Tools/omp-bridge' pair")
        context.executable = "omp-bridge"
        context.environment["PATH"] = "/nonexistent"
        #expect(context.invocation(program: "omp-bridge") == "omp-bridge pair")
    }

    @Test func aMistypedOptionIsRefusedWithTheUsage() {
        let machine = Machine()
        for arguments in [["--nope"], ["--link-only", "--json"], ["--color"], ["--color", "red"]] {
            let outcome = machine.pair(arguments)
            #expect(outcome.status == 2, "\(arguments)")
            #expect(outcome.stdout.isEmpty)
            #expect(outcome.stderr.contains("usage: pair"))
        }
    }

    @Test func theHomeTheCommandReadsIsTheOneTheEnvironmentNames() {
        let named = ProcessInfo.processInfo.environment["HOME"] ?? ""
        #expect(named.isEmpty || PairingContext.live.home == named)
    }

    @Test func pairIsAKnownCommandAndAnythingElseStillIsNot() {
        #expect(PairingCommand.isRequest(["omp-bridge", "pair"]))
        #expect(!PairingCommand.isRequest(["omp-bridge"]))
        #expect(!PairingCommand.isRequest(["omp-bridge", "--version"]))
        #expect(OmpVersion.unknownCommand(["omp-bridge", "pair"]) == nil)
        #expect(OmpVersion.unknownCommand(["omp-bridge", "pair", "--json"]) == nil)
        #expect(OmpVersion.unknownCommand(["omp-bridge", "frobnicate"]) == "frobnicate")
    }
}
