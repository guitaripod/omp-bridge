/// What oh-my-pi is told about where its replies are read, added after its own system prompt with
/// `--append-system-prompt` rather than replacing it, so the engine keeps its tool guidance and its
/// rules. Only facts about the screen, never a style of its own, so it does not argue with the
/// person's own AGENTS.md. Fixed text, so every request's prompt stays the same and cacheable, and
/// worded "may" because the same conversation can be picked up again in a terminal.
/// `OMP_CLIENT_NOTE=0` leaves it off.
enum ClientNote {
    static let text = """
        This session is driven from Tailscode, an app on the user's phone, tablet or computer. \
        They may not be at this machine, so do not count on them seeing its terminal, windows or \
        browser. Your replies render as Markdown in a chat view: fenced code gets a copy button, \
        links are tappable and wide tables scroll sideways. Markdown images, raw HTML, Mermaid \
        and LaTeX do not render, and file paths are not tappable. Notifications and the chat list \
        show only the first sentence or two of your reply, so lead with the outcome.
        """

    static func arguments(enabled: Bool) -> [String] {
        enabled ? ["--append-system-prompt", text] : []
    }
}
