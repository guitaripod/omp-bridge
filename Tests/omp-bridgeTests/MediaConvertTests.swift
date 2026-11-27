import Foundation
import Testing

@testable import omp_bridge

@Suite("Media conversion and the note an app gets", .serialized)
struct MediaConvertTests {
    @Test("Apple players read MP4, QuickTime and the usual audio as they are")
    func knowsWhatApplePlays() {
        #expect(MediaConvert.playsOnApple("/a/clip.mov"))
        #expect(!MediaConvert.playsOnApple("/a/run.webm"))
        #expect(!MediaConvert.playsOnApple("/a/voice.opus"))
    }

    @Test("an Ogg song becomes an M4A once")
    func convertsAnOggOnce() async throws {
        guard let ffmpeg = MediaConvert.ffmpeg() else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("voice.ogg").path
        let made = Shell.runCapturingErrors(
            ffmpeg,
            ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
             "-t", "1", "-c:a", "libopus", source], timeout: 120)
        try #require(made.isEmpty, "\(made)")
        let size = try #require(FileBrowsing.readableSize(source, cap: Int.max))
        let copy = try await MediaConvert.shared.playableCopy(of: source, size: size)
        #expect(copy.hasSuffix(".m4a"))
        #expect(try await MediaConvert.shared.playableCopy(of: source, size: size) == copy)
        try? FileManager.default.removeItem(atPath: copy)
    }

    @Test("an app that shows named files gets the note that says so")
    func noteFollowsTheApp() {
        #expect(ClientNote.arguments(enabled: true, mediaByPath: true).last == ClientNote.mediaText)
        #expect(ClientNote.arguments(enabled: true).last == ClientNote.text)
        #expect(!ClientNote.mediaText.contains("\n"))
        #expect(ClientNote.mediaText.count < 800)
    }
}
