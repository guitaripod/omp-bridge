import Foundation
import Testing

@testable import omp_bridge

@Suite struct ProcessReleaseTests {
    final class Watch: @unchecked Sendable {
        weak var process: Process?
        weak var pipe: Pipe?
    }

    @Test func finishedProcessLetsGoOfItsPipe() async throws {
        let watch = Watch()
        try startExitingChild(watch: watch)
        #expect(await released(watch))
    }

    @Test(arguments: [false, true])
    func anEngineThatEndedHoldsNoPipeOfItsOwn(stoppedByBridge: Bool) async throws {
        #if os(Linux)
            let root = makeTempDir("process-release")
            let binary = root + "/fake-omp"
            let body = """
                #!/bin/sh
                echo '{"type":"ready","supportedProtocolVersions":[1]}'
                while IFS= read -r line; do exit 0; done
                """
            try body.write(toFile: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
            let engine = OmpProcess(ompBin: binary, directory: root) { _ in }
            try await engine.start()
            let pid = try #require(await engine.processID)
            let pipes = ["/proc/\(pid)/fd/0", "/proc/\(pid)/fd/1"].compactMap {
                try? FileManager.default.destinationOfSymbolicLink(atPath: $0)
            }
            #expect(pipes.count == 2 && pipes.allSatisfy { $0.hasPrefix("pipe:") })
            #expect(pipes.allSatisfy(heldHere))
            if stoppedByBridge {
                await engine.stop()
            } else {
                let answer = await engine.request("get_state", timeout: 5)
                #expect(!answer.success)
            }
            for pipe in pipes {
                #expect(await letGo(pipe), "the bridge still holds \(pipe) after its engine ended")
            }
        #endif
    }

    private func startExitingChild(watch: Watch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo done"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.terminationHandler = { $0.releaseFinished() }
        watch.process = process
        watch.pipe = pipe
        try process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
    }

    private func released(_ watch: Watch) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while watch.process != nil || watch.pipe != nil {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func letGo(_ pipe: String) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while heldHere(pipe) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func heldHere(_ pipe: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        return names.contains { name in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/" + name))
                == pipe
        }
    }
}
