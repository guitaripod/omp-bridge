import Foundation
import Testing

@testable import omp_bridge

@Suite struct VersionTests {
    @Test func theCompiledVersionIsTheNewestNumberedChangelogHeading() throws {
        let changelog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let head = text.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("## ") else { return nil }
                let word = line.dropFirst(3).split(separator: " ").first.map(String.init)
                return word.flatMap { $0.first?.isNumber == true ? $0 : nil }
            }
            .first
        #expect(head == OmpVersion.fallback)
    }

    @Test func versionIsAskedForByFlagOrWord() {
        #expect(OmpVersion.isVersionRequest(["omp-bridge", "--version"]))
        #expect(OmpVersion.isVersionRequest(["omp-bridge", "version"]))
    }

    @Test func nothingElseIsAVersionRequest() {
        #expect(!OmpVersion.isVersionRequest(["omp-bridge"]))
        #expect(!OmpVersion.isVersionRequest(["omp-bridge", "pair"]))
        #expect(!OmpVersion.isVersionRequest(["--version"]))
    }

    @Test func theLineNamesTheBridgeAndItsVersion() {
        #expect(OmpVersion.versionLine() == "omp-bridge \(OmpVersion.fallback)")
    }

    @Test func anArgumentTheBridgeDoesNotKnowIsRefusedRatherThanIgnored() {
        #expect(OmpVersion.unknownCommand(["omp-bridge", "frobnicate"]) == "frobnicate")
        #expect(OmpVersion.unknownCommand(["omp-bridge", "--port", "1"]) == "--port")
        #expect(OmpVersion.unknownCommand(["omp-bridge"]) == nil)
        #expect(OmpVersion.unknownCommand(["omp-bridge", "--version"]) == nil)
    }
}
