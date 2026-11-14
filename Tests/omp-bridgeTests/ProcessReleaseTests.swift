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
            try writeExecutable(body, to: binary)
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

    @Test func aProgramBusyForAMomentIsStillRun() async throws {
        let path = makeTempDir("busy-program") + "/program"
        try writeExecutable("#!/bin/sh\nexit 0\n", to: path)
        let writer = Spawning.serialized { open(path, O_WRONLY) }
        #expect(writer >= 0)
        Thread.detachNewThread {
            usleep(60_000)
            close(writer)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        try process.runAllowingBusyExecutable()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func startExitingChild(watch: Watch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo done"]
        process.terminationHandler = { $0.releaseFinished() }
        let pipe = try Spawning.serialized {
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.runAllowingBusyExecutable()
            return pipe
        }
        watch.process = process
        watch.pipe = pipe
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
