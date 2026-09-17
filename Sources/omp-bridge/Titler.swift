import Foundation

/// Names a conversation after its first exchange with a one-shot `omp -p` call — no session file,
/// no tools, no skills, no thinking — so a title costs one short completion rather than a second
/// agent.
///
/// omp writes an empty title row at the top of every transcript and only ever fills it in from its
/// own terminal UI; under the bridge that row stays empty for the life of the chat. Without this
/// every session kept the slice of first prompt it was born with, which for a slash command read
/// like a command line rather than a conversation.
enum Titler {
    /// The title for an exchange, or nil when the call failed, timed out or came back with
    /// something that is not a title. A nil is never fatal: the row keeps the name it has.
    ///
    /// The session's own engine is asked first and whatever omp reaches for by default second, so
    /// a chat is not left with a command line for a name because the model it happened to run on
    /// wants a key this service does not carry, or is too large to load for six words.
    static func title(
        binary: String, model: String?, cwd: String, user: String, assistant: String
    ) async -> String? {
        try? FileManager.default.createDirectory(
            atPath: cwd, withIntermediateDirectories: true)
        let prompt = """
            Write a title for this coding-agent conversation: 3 to 6 words, plain text, \
            no quotes, no trailing period. Reply with the title only.

            User: \(condense(user, cap: 600))
            Assistant: \(condense(assistant, cap: 400))
            """
        if let raw = await run(binary: binary, model: model, cwd: cwd, prompt: prompt),
            let named = clean(raw)
        {
            return named
        }
        guard model != nil else { return nil }
        return await run(binary: binary, model: nil, cwd: cwd, prompt: prompt).flatMap(clean)
    }

    private static func condense(_ text: String, cap: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(flattened.prefix(cap))
    }

    /// The title inside whatever the engine printed. A local model is the likely titler here — it
    /// is the one already warm on the machine — and a local model will sometimes think out loud or
    /// announce itself first, so the last real line wins and anything that is not title-shaped is
    /// refused rather than written into the list.
    static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(
            of: "(?s)<think>.*?</think>", with: " ", options: .regularExpression)
        if let end = text.range(of: "</think>", options: .backwards) {
            text = String(text[end.upperBound...])
        }
        guard
            var line = text
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty })
        else { return nil }
        line = line.replacingOccurrences(
            of: "^(?i)(title|session title)\\s*[:\\-]\\s*", with: "",
            options: .regularExpression)
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`*_ .,:;"))
        guard !line.isEmpty, line.count <= 70, line.split(separator: " ").count <= 12 else {
            return nil
        }
        return line
    }

    private static func run(
        binary: String, model: String?, cwd: String, prompt: String
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                var arguments = [
                    "-p", "--no-session", "--no-tools", "--no-lsp", "--no-skills", "--no-rules",
                    "--no-extensions", "--no-title", "--thinking", "off",
                    "--system-prompt", "You write short titles.",
                ]
                if let model, !model.isEmpty { arguments.append(contentsOf: ["--model", model]) }
                arguments.append(prompt)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = OmpProcess.pathReachingRuntime(
                    of: binary, base: environment["PATH"])
                process.environment = environment
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Long enough for a cold local engine to load and answer, short enough that a wedged one is
    /// let go of rather than held onto.
    private static let timeout: TimeInterval = 60
}
