import Foundation
@testable import omp_bridge

func makeTempDir(_ name: String) -> String {
    let dir = NSTemporaryDirectory() + "omp-bridge-tests/\(name)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a script and marks it executable while no child is being started. Foundation on Linux
/// lets a child started at that moment inherit the half-written file's descriptor (see
/// ``Spawning``), and a long-lived child holds it open for good, so running the script is refused
/// with "text file busy" however often it is retried.
func writeExecutable(_ body: String, to path: String) throws {
    try Spawning.serialized {
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
