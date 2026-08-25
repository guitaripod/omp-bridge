import Foundation

struct DiscoveredSession: Sendable {
    let ompSessionID: String
    let file: String
    let title: String
    let directory: String?
    let updatedAt: Date
    let firstUserText: String?
}

enum Discovery {
    static func scan(root: String, hidden: [String], claimedFiles: Set<String>) -> [DiscoveredSession] {
        let fm = FileManager.default
        var found: [DiscoveredSession] = []
        if root.hasSuffix(".jsonl") || hasJSONLChildren(root) {
            collect(fromDirectory: root, hidden: hidden, claimedFiles: claimedFiles, into: &found)
            return found.sorted { $0.updatedAt > $1.updatedAt }
        }
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for dir in dirs {
            let dirPath = root + "/" + dir
            collect(fromDirectory: dirPath, hidden: hidden, claimedFiles: claimedFiles, into: &found)
        }
        return found.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func hasJSONLChildren(_ path: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.contains { $0.hasSuffix(".jsonl") }
    }

    private static func collect(
        fromDirectory dirPath: String, hidden: [String], claimedFiles: Set<String>,
        into found: inout [DiscoveredSession]
    ) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
        for file in files where file.hasSuffix(".jsonl") {
            let path = dirPath + "/" + file
            if claimedFiles.contains(path) { continue }
            guard let loaded = loadLight(path) else { continue }
            if let id = loaded.ompSessionID, hidden.contains(id) { continue }
            found.append(
                DiscoveredSession(
                    ompSessionID: loaded.ompSessionID
                        ?? file.replacingOccurrences(of: ".jsonl", with: ""),
                    file: path, title: loaded.title ?? "Session",
                    directory: loaded.cwd,
                    updatedAt: TranscriptLoader.mtime(path) ?? Date(),
                    firstUserText: loaded.firstUserText))
        }
    }

    private static func loadLight(_ path: String) -> (ompSessionID: String?, title: String?, cwd: String?, firstUserText: String?)? {
        guard let raw = FileManager.default.contents(atPath: path), !raw.isEmpty else { return nil }
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
