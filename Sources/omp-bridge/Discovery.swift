import Foundation

struct DiscoveredSession: Sendable {
    let ompSessionID: String
    let file: String
    let title: String
    let directory: String?
    let updatedAt: Date
    let firstUserText: String?
    let model: String?
    let effort: String?
}

/// Per-path light-parse results keyed by mtime, so the observer's once-a-second scan re-reads a
/// transcript only when it actually changed instead of loading every file on the machine each tick.
final class DiscoveryCache {
    struct Light {
        let mtime: Date
        let ompSessionID: String?
        let title: String?
        let cwd: String?
        let firstUserText: String?
        let model: String?
        let effort: String?
    }

    var lights: [String: Light] = [:]
}

enum Discovery {
    static func isJunkDirectory(_ path: String) -> Bool {
        let junkPrefixes = ["/tmp", "/private/tmp", "/var/folders", "/var/tmp"]
        return junkPrefixes.contains { path.hasPrefix($0) }
    }

    static func scan(
        root: String, hidden: [String], claimedFiles: Set<String>, cache: DiscoveryCache? = nil
    ) -> [DiscoveredSession] {
        let fm = FileManager.default
        var found: [DiscoveredSession] = []
        if root.hasSuffix(".jsonl") || hasJSONLChildren(root) {
            collect(fromDirectory: root, hidden: hidden, claimedFiles: claimedFiles, cache: cache, into: &found)
            return found.filter { $0.directory.map { !isJunkDirectory($0) } ?? true }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for dir in dirs {
            let dirPath = root + "/" + dir
            collect(fromDirectory: dirPath, hidden: hidden, claimedFiles: claimedFiles, cache: cache, into: &found)
        }
        return found.filter { $0.directory.map { !isJunkDirectory($0) } ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func hasJSONLChildren(_ path: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.contains { $0.hasSuffix(".jsonl") }
    }

    private static func collect(
        fromDirectory dirPath: String, hidden: [String], claimedFiles: Set<String>,
        cache: DiscoveryCache?, into found: inout [DiscoveredSession]
    ) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
        for file in files where file.hasSuffix(".jsonl") {
            let path = dirPath + "/" + file
            if claimedFiles.contains(path) { continue }
            let mtime = TranscriptLoader.mtime(path) ?? Date()
            let light: DiscoveryCache.Light
            if let cached = cache?.lights[path], cached.mtime == mtime {
                light = cached
            } else {
                guard let loaded = loadLight(path) else { continue }
                light = DiscoveryCache.Light(
                    mtime: mtime, ompSessionID: loaded.ompSessionID, title: loaded.title,
                    cwd: loaded.cwd, firstUserText: loaded.firstUserText,
                    model: loaded.model, effort: loaded.effort)
                cache?.lights[path] = light
            }
            if let id = light.ompSessionID, hidden.contains(id) { continue }
            if hidden.contains(file.replacingOccurrences(of: ".jsonl", with: "")) { continue }
            found.append(
                DiscoveredSession(
                    ompSessionID: light.ompSessionID
                        ?? file.replacingOccurrences(of: ".jsonl", with: ""),
                    file: path, title: listedTitle(light),
                    directory: light.cwd,
                    updatedAt: mtime,
                    firstUserText: light.firstUserText,
                    model: light.model, effort: light.effort))
        }
    }

    /// A transcript names itself the way an adopted one does — after the first thing said in
    /// it — from the moment it is found on disk. omp writes an empty title row at the top of every
    /// session, and a list that waited for the person to open the chat before reading past it
    /// showed "Session" for a conversation that had been running for an hour.
    private static func listedTitle(_ light: DiscoveryCache.Light) -> String {
        if let title = light.title { return title }
        guard let first = light.firstUserText else { return "Session" }
        let derived = OmpSession.derivedTitle(from: first)
        return OmpSession.isPlaceholderTitle(derived) ? "Session" : derived
    }

    private struct LightParse {
        var ompSessionID: String?
        var title: String?
        var cwd: String?
        var firstUserText: String?
        var model: String?
        var effort: String?
    }

    private static func loadLight(_ path: String) -> LightParse? {
        guard let handle = FileHandle(forReadingAtPath: path),
            let raw = try? handle.read(upToCount: 262_144), !raw.isEmpty
        else { return nil }
        try? handle.close()
        var parse = LightParse()
        for line in raw.split(separator: UInt8(0x0A)).prefix(40) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) else { continue }
            let value = JSONValue.from(obj)
            switch value["type"]?.stringValue {
            case "session":
                parse.ompSessionID = value["id"]?.stringValue
                parse.cwd = value["cwd"]?.stringValue
            case "title":
                if let t = value["title"]?.stringValue, !t.isEmpty { parse.title = t }
            case "model_change":
                if let model = value["model"]?.stringValue { parse.model = model }
            case "thinking_level_change":
                parse.effort = TranscriptLoader.thinkingLevel(in: value)
            case "message":
                if parse.firstUserText == nil, value["message"]?["role"]?.stringValue == "user" {
                    let texts = (value["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                        block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
                    }
                    parse.firstUserText = texts.joined(separator: " ")
                }
            default:
                break
            }
            if parse.ompSessionID != nil, parse.cwd != nil, parse.firstUserText != nil { break }
        }
        return parse
    }
}
