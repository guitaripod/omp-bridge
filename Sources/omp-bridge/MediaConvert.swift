import Foundation

/// A copy of a file Apple's players can read, made once with ffmpeg and kept.
///
/// AVFoundation opens MP4, QuickTime and the usual audio containers and nothing else, while agents
/// write WebM (Playwright records its videos as WebM), Matroska and Ogg. A ticket asked for an
/// Apple player (`playable: "apple"`) for such a file is a ticket to this copy: H.264 and AAC in an
/// MP4 with its index at the front for a video, AAC in an M4A for a song. The copy is named by the
/// file's path, size and modification time, so the same file is converted once and a file that
/// changed is converted again; copies nobody has asked for in a week are removed.
actor MediaConvert {
    static let shared = MediaConvert()

    enum Failure: Error, Equatable {
        case noConverter
        case failed(String)
    }

    private var running: [String: Task<String, any Error>] = [:]
    private var pruned = false

    /// Whether Apple's players read a file of this extension as it is.
    nonisolated static func playsOnApple(_ path: String) -> Bool {
        applePlayable.contains((path as NSString).pathExtension.lowercased())
    }

    nonisolated static let applePlayable: Set<String> = [
        "mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "caf",
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "avif", "bmp", "tif", "tiff",
    ]

    nonisolated static let audioOnly: Set<String> = ["ogg", "oga", "opus", "wma", "amr"]

    /// The path of a copy Apple's players can read, converting the file the first time it is asked
    /// for. Concurrent asks for one file share one conversion.
    func playableCopy(of path: String, size: Int) async throws -> String {
        guard let ffmpeg = Self.ffmpeg() else { throw Failure.noConverter }
        let modified =
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let audio = Self.audioOnly.contains((path as NSString).pathExtension.lowercased())
        let target = Self.directory.appendingPathComponent(
            Self.stem("\(path)|\(size)|\(Int(modified))") + (audio ? ".m4a" : ".mp4")).path
        if FileManager.default.fileExists(atPath: target) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target)
            return target
        }
        if let underway = running[target] { return try await underway.value }
        pruneOnce()
        let task = Task<String, any Error> {
            try await Self.convert(path, to: target, audio: audio, ffmpeg: ffmpeg)
            return target
        }
        running[target] = task
        defer { running[target] = nil }
        return try await task.value
    }

    /// ffmpeg off the cooperative pool: `Shell` waits on a semaphore, and a blocked pool thread is
    /// a turn somebody else is waiting for.
    private static func convert(_ source: String, to target: String, audio: Bool, ffmpeg: String)
        async throws
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = target + ".part" + (audio ? ".m4a" : ".mp4")
        try? FileManager.default.removeItem(atPath: partial)
        let arguments = Self.arguments(source: source, target: partial, audio: audio)
        let complaint: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Shell.runCapturingErrors(ffmpeg, arguments, timeout: 900))
            }
        }
        guard complaint.isEmpty, FileManager.default.fileExists(atPath: partial) else {
            try? FileManager.default.removeItem(atPath: partial)
            let reason = complaint.split(separator: "\n").suffix(2).joined(separator: " ")
            throw Failure.failed(reason.isEmpty ? "ffmpeg wrote nothing" : reason)
        }
        try FileManager.default.moveItem(atPath: partial, toPath: target)
    }

    nonisolated static func arguments(source: String, target: String, audio: Bool) -> [String] {
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source]
        if audio {
            arguments += ["-vn", "-map", "0:a:0", "-c:a", "aac", "-b:a", "192k"]
        } else {
            arguments += [
                "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast",
                "-crf", "21", "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                "-c:a", "aac", "-b:a", "160k",
            ]
        }
        return arguments + ["-movflags", "+faststart", target]
    }

    nonisolated static func ffmpeg() -> String? {
        if let found = Shell.which("ffmpeg") { return found.path }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    nonisolated static var directory: URL {
        #if os(macOS)
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
            let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map {
                URL(fileURLWithPath: $0)
            } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        #endif
        return base.appendingPathComponent("omp-bridge/converted", isDirectory: true)
    }

    /// FNV-1a over the file's path, size and modification time.
    nonisolated static func stem(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func pruneOnce() {
        guard !pruned else { return }
        pruned = true
        let directory = Self.directory
        Task.detached(priority: .background) {
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
    }
}
