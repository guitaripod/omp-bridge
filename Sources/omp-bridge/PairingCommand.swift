import Foundation
import PairingKit

enum PairingCommand {
    struct Outcome: Equatable {
        var status: Int32
        var stdout = ""
        var stderr = ""
    }

    static let program = "omp-bridge"
    static let defaultPort = 4099

    static func isRequest(_ arguments: [String]) -> Bool {
        arguments.dropFirst().first == "pair"
    }

    struct Settings: Equatable {
        var port: Int
        var password: String
        var tailscaleOverride: String?
    }

    static func settings(_ context: PairingContext) -> Settings {
        let file = PairingConfigFile.values(at: "\(context.home)/.config/omp-bridge.env")
        return Settings(
            port: context.value("OMP_PORT", file: file).flatMap { Int($0) } ?? defaultPort,
            password: context.value("OMP_PASSWORD", file: file) ?? "",
            tailscaleOverride: context.value("OMP_TAILSCALE", file: file))
    }

    static func keyDecision(_ settings: Settings) -> (key: String?, note: String) {
        guard !settings.password.isEmpty else {
            return (nil, "No password is in this link because none is set.")
        }
        return (
            settings.password,
            "This link carries the password of this bridge, because omp-bridge lets nobody in without it and does not check the tailnet. Anyone who sees the link can use the bridge; keep it to yourself."
        )
    }

    static func run(arguments: [String], context: PairingContext) -> Outcome {
        guard let options = PairingOptions.parse(arguments) else {
            return Outcome(status: 2, stderr: "\(program) pair: \(PairingOptions.usage)\n")
        }
        let settings = settings(context)
        let cli = context.anyTailscale(override: settings.tailscaleOverride)
        let choice = PairingHostChoice.resolve(
            tailscaleFound: cli != nil, reading: context.reading(cli: cli),
            hostname: context.hostname, port: settings.port, agent: .omp)
        guard let choice else {
            return Outcome(
                status: 1,
                stderr:
                    "\(program) pair: this computer's name \"\(context.hostname)\" cannot be used in a pairing link.\n"
            )
        }
        var decision = keyDecision(settings)
        let name = PairingHostChoice.displayName(context.hostname)
        var link = PairingLink(
            host: choice.host, port: settings.port, agent: .omp, name: name, key: decision.key)
        if link == nil, decision.key != nil {
            decision = (nil, "The password is too long to go in a link; enter it in Tailscode by hand.")
            link = PairingLink(host: choice.host, port: settings.port, agent: .omp, name: name)
        }
        guard let link else {
            return Outcome(
                status: 1,
                stderr: "\(program) pair: port \(settings.port) cannot be used in a pairing link.\n")
        }
        let text = link.url.absoluteString
        let code = (try? QRCode.encode(text)) ?? (try? QRCode.encode(text, level: .low))
        if code == nil {
            decision.note += " The link is too long to draw as a code, so paste it into Tailscode instead."
        }
        let showQR = (options.anyHost || choice.onTailnet) && code != nil
        let plan = PairingPlan(
            link: link, choice: choice, keyIncluded: link.key != nil, keyNote: decision.note,
            again: context.invocation(program: program), qr: code)
        if options.json {
            return Outcome(status: 0, stdout: plan.json(showQR: showQR) + "\n")
        }
        if options.linkOnly {
            guard choice.onTailnet || options.anyHost else {
                return Outcome(
                    status: 3,
                    stderr: PairingPlan.offTailnetNote(reason: choice.offTailnet ?? "", qrShown: false)
                        + " Add --any-host to print the link anyway.\n")
            }
            return Outcome(status: 0, stdout: link.url.absoluteString + "\n")
        }
        let color: Bool
        switch options.color {
        case .always: color = true
        case .never: color = false
        case .auto: color = context.isTerminal
        }
        return Outcome(
            status: 0, stdout: plan.plain(color: color, environment: context.environment, showQR: showQR))
    }
}
