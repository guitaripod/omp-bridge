import Foundation

/// The agents a workflow run fanned out, as the workflow extension reports them on its tool's
/// `details.workflow` while the run goes and in the result it ends with. omp runs those agents in
/// sessions of its own that it lists nowhere, so this report is the only way a client learns of
/// them; each is typed and tied to the call that started its run the way claude-bridge ties a
/// Claude workflow's agents to theirs.
enum WorkflowAgents {
    static let agentType = "workflow-subagent"

    static func read(_ details: JSONValue?, toolCallID: String, now: Date) -> [SubagentState] {
        guard let roster = details?["workflow"], let run = roster["run"]?.stringValue, !run.isEmpty,
            let agents = roster["agents"]?.arrayValue
        else { return [] }
        let call = roster["call"]?.stringValue ?? toolCallID
        return agents.compactMap { agent in
            guard let id = agent["id"]?.stringValue, !id.isEmpty else { return nil }
            let ended = date(agent["endedAt"])
            var state = SubagentState(
                id: id, title: label(agent["label"]?.stringValue),
                active: agent["status"]?.stringValue == "running", updatedAt: ended ?? now)
            state.agentType = agentType
            state.toolUseID = call
            state.startedAt = date(agent["startedAt"])
            state.runID = run
            return state
        }
    }

    /// The roster the run ended with: every agent it reports is over, whatever its last progress
    /// said, because nothing of a run outlives the call that ran it.
    static func settled(_ details: JSONValue?, toolCallID: String, now: Date) -> [SubagentState] {
        read(details, toolCallID: toolCallID, now: now).map { agent in
            var agent = agent
            agent.active = false
            agent.currentTool = nil
            return agent
        }
    }

    private static func label(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "agent" }
        return text
    }

    private static func date(_ value: JSONValue?) -> Date? {
        value?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
