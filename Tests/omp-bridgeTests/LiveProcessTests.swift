import Foundation
import Testing

@testable import omp_bridge

@Suite struct LiveProcessTests {
    static let ompPath = ProcessInfo.processInfo.environment["OMP_TEST_BIN"] ?? ""

    @Test func requestRoundTripAgainstRealOmp() async throws {
        guard !Self.ompPath.isEmpty else { return }
        let workdir = NSTemporaryDirectory() + "omp-live-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        let process = OmpProcess(ompBin: Self.ompPath, directory: workdir) { _ in }
        try await process.start()
        let state = await process.request("get_state", timeout: 60)
        #expect(state.success)
        await process.stop()
    }
}
