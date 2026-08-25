import Foundation
@testable import omp_bridge

func makeTempDir(_ name: String) -> String {
    let dir = NSTemporaryDirectory() + "omp-bridge-tests/\(name)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
