import Foundation

struct MachineQuiet: Codable, Sendable {
    var quiet: Bool
    var turns: Int
    var reason: String?

    static let unknown = MachineQuiet(
        quiet: false, turns: 0, reason: "This machine has not finished counting what it is doing.")

    static func read(turns: Int) -> MachineQuiet {
        guard turns > 0 else { return MachineQuiet(quiet: true, turns: 0) }
        return MachineQuiet(
            quiet: false, turns: turns,
            reason: turns == 1
                ? "A turn is running on that machine."
                : "\(turns) turns are running on that machine.")
    }
}

actor QuietRegistry {
    private var turns = 0
    private var observed = false

    func setTurns(_ count: Int) {
        turns = max(0, count)
        observed = true
    }

    func increment() {
        turns += 1
        observed = true
    }

    func decrement() {
        turns = max(0, turns - 1)
        observed = true
    }

    func read() -> MachineQuiet {
        guard observed else { return .unknown }
        return .read(turns: turns)
    }
}
