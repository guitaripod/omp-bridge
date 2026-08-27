import Foundation

struct DiscoveredSession: Sendable {
    let ompSessionID: String
    let file: String
    let title: String
    let directory: String?
    let updatedAt: Date
    let firstUserText: String?
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
                    cwd: loaded.cwd, firstUserText: loaded.firstUserText)
                cache?.lights[path] = light
            }
            if let id = light.ompSessionID, hidden.contains(id) { continue }
            if hidden.contains(file.replacingOccurrences(of: ".jsonl", with: "")) { continue }
            found.append(
                DiscoveredSession(
                    ompSessionID: light.ompSessionID
                        ?? file.replacingOccurrences(of: ".jsonl", with: ""),
                    file: path, title: light.title ?? "Session",
                    directory: light.cwd,
                    updatedAt: mtime,
                    firstUserText: light.firstUserText))
        }
    }

    private static func loadLight(_ path: String) -> (ompSessionID: String?, title: String?, cwd: String?, firstUserText: String?)? {
        guard let handle = FileHandle(forReadingAtPath: path),
            let raw = try? handle.read(upToCount: 262_144), !raw.isEmpty
        else { return nil }
        try? handle.close()
        var id: String?
        var title: String?
        var cwd: String?
        var firstText: String?
        for line in raw.split(separator: UInt8(0x0A)).prefix(40) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) else { continue }
            let value = JSONValue.from(obj)
            switch value["type"]?.stringValue {
            case "session":
                id = value["id"]?.stringValue
                cwd = value["cwd"]?.stringValue
            case "title":
                if let t = value["title"]?.stringValue, !t.isEmpty { title = t }
            case "message":
                if firstText == nil, value["message"]?["role"]?.stringValue == "user" {
                    let texts = (value["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                        block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
                    }
                    firstText = texts.joined(separator: " ")
                }
            default:
                break
            }
            if id != nil, cwd != nil, firstText != nil { break }
        }
        return (id, title, cwd, firstText)
    }
}
