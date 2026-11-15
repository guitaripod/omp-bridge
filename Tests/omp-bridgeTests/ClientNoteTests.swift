import Foundation
import Testing

@testable import omp_bridge

/// A conversation's engine is started with the note that says where its replies are read,
/// appended after oh-my-pi's own prompt, never in place of it.
@Suite("Client note")
struct ClientNoteTests {
    private struct Engine {
        let root: String
        let binary: String
        let argumentLog: String

        init() throws {
            root = makeTempDir("client-note")
            argumentLog = root + "/arguments.log"
            binary = root + "/fake-omp"
            let body = """
                #!/bin/sh
                for argument in "$@"; do printf '%s\\n' "$argument" >> "\(argumentLog)"; done
                echo '{"type":"ready","supportedProtocolVersions":[1]}'
                while IFS= read -r line; do
                  id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
                  cmd=$(printf '%s' "$line" | sed -n 's/.*"type":"\\([^"]*\\)".*/\\1/p')
                  printf '{"type":"response","id":"%s","command":"%s","success":true,"data":{}}\\n' "$id" "$cmd"
                done
                """
            try writeExecutable(body, to: binary)
        }

        func arguments(clientNote: Bool) async throws -> [String] {
            var config = Config(
                port: 0, bind: "", password: "", workdir: root, ompBin: binary,
                storePath: root + "/sessions.json", stateDir: root, srcPath: nil,
                defaultModel: nil, defaultEffort: "medium", titleModel: nil, waitMax: 10800)
            config.clientNote = clientNote
            let session = OmpSession(
                title: "Test", directory: root, model: "", effort: "medium",
                ompSessionFile: nil, config: config, hub: Hub(), quietRegistry: QuietRegistry())
            let process = try await session.ensureProcess()
            var arguments: [String] = []
            let deadline = Date().addingTimeInterval(5)
            while arguments.isEmpty, Date() < deadline {
                let text = (try? String(contentsOfFile: argumentLog, encoding: .utf8)) ?? ""
                if text.contains("rpc") {
                    arguments = text.split(separator: "\n").map(String.init)
                } else {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            await process.stop()
            return arguments
        }
    }

    @Test func theEngineIsToldWhereItsRepliesAreRead() async throws {
        let engine = try Engine()
        let arguments = try await engine.arguments(clientNote: true)
        let flag = try #require(arguments.firstIndex(of: "--append-system-prompt"))
        #expect(arguments[flag + 1] == ClientNote.text)
        #expect(Array(arguments.prefix(2)) == ["--mode", "rpc"])
        #expect(!arguments.contains("--system-prompt"))
    }

    @Test func theNoteStaysOffWhenTurnedOff() async throws {
        let engine = try Engine()
        let arguments = try await engine.arguments(clientNote: false)
        #expect(arguments == ["--mode", "rpc"])
    }

    @Test func isOneFixedLine() {
        #expect(!ClientNote.text.contains("\n"))
        #expect(ClientNote.text.hasPrefix("This session is driven from Tailscode"))
    }
}
