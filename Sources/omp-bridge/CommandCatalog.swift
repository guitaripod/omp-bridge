import Foundation

/// The slash catalog as omp states it, translated into claude-bridge's DTO once for every
/// road it reaches a client by: the `available_commands_update` frame a live session hears,
/// and the `get_available_commands` answer a scratch process gives for a directory nobody has
/// opened a chat in.
enum CommandCatalog {
    static func parse(_ list: [JSONValue]) -> [AgentCommandDTO] {
        list.compactMap { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { return nil }
            return AgentCommandDTO(
                name: name, description: entry["description"]?.stringValue,
                argumentHint: entry["input"]?["hint"]?.stringValue,
                source: source(of: entry["source"]?.stringValue),
                scope: nil)
        }
    }

    /// omp's six origins folded onto the vocabulary claude-bridge clients already render: a
    /// skill stays a skill, an extension is what a plugin is elsewhere, an MCP prompt is MCP, and
    /// a command written by hand — a file, a custom one — is the user's own.
    private static func source(of word: String?) -> String {
        switch word {
        case "skill": return "skill"
        case "extension": return "plugin"
        case "mcp_prompt": return "mcp"
        case "custom", "file": return "user"
        default: return "builtin"
        }
    }
}
