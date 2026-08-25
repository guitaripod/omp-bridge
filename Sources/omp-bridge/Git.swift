import Foundation

struct GitChange: Encodable, Sendable {
    var path: String
    var original: String?
    var index: String?
    var worktree: String?
    var untracked: Bool = false
    var directory: Bool = false
    var conflicted: Bool = false
    var submodule: Bool = false
    var binary: Bool = false
    var insertions: Int = 0
    var deletions: Int = 0
    var stagedInsertions: Int = 0
    var stagedDeletions: Int = 0
    var bytes: Int?
    var contains: Int?
    var containsAtLeast: Bool = false
}

struct GitCommitSummary: Encodable, Sendable {
    var hash: String
    var short: String
    var subject: String
    var author: String
    var at: Date
    var refs: [String]
}

struct GitSnapshot: Encodable, Sendable {
    var root: String
    var repo: Bool = true
    var branch: String?
    var detached: Bool = false
    var head: String?
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var stashes: Int = 0
    var operation: String?
    var remote: String?
    var fetchedAt: Date?
    var changes: [GitChange] = []
    var commits: [GitCommitSummary] = []
    var truncated: Bool = false
    var changedTotal: Int = 0
}

struct GitPatch: Encodable, Sendable {
    var path: String
    var staged: Bool
    var patch: String
    var binary: Bool = false
    var truncated: Bool = false
}

struct GitCommitDetail: Encodable, Sendable {
    var hash: String
    var short: String
    var subject: String
    var body: String?
    var author: String
    var email: String?
    var at: Date
    var refs: [String]
    var parents: [String]
    var files: [GitChange]
    var patch: String?
    var truncated: Bool = false
}

enum Git {
    static let pathLimit = 400
    static let patchLimit = 400_000
    static let commitLimit = 30

    static func root(of directory: String) -> String? {
        Shell.run("git", ["rev-parse", "--show-toplevel"], cwd: directory, timeout: 10)
            .trimmedOrNil()
    }

    static func snapshot(directory: String) -> GitSnapshot? {
        guard let root = root(of: directory) else { return nil }
        var snapshot = GitSnapshot(root: root)
        parseStatus(
            Shell.data(
                "git",
                ["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "-z"],
                cwd: root, timeout: 20), into: &snapshot)
        applyNumstat(root: root, to: &snapshot)
        measureUntracked(root: root, in: &snapshot)
        snapshot.changedTotal = snapshot.changes.count
        if snapshot.changes.count > pathLimit {
            snapshot.changes = Array(snapshot.changes.prefix(pathLimit))
            snapshot.truncated = true
        }
        snapshot.commits = commits(root: root, limit: commitLimit)
        snapshot.stashes = Shell.run("git", ["stash", "list"], cwd: root, timeout: 10)
            .split(separator: "\n").count
        snapshot.operation = operation(root: root)
        snapshot.remote = remote(root: root)
        snapshot.fetchedAt = fetchedAt(root: root)
        return snapshot
    }

    static func patch(directory: String, path: String, staged: Bool) -> GitPatch? {
        guard let root = root(of: directory) else { return nil }
        var arguments = ["diff", "--no-color", "--no-ext-diff"]
        if staged { arguments.append("--cached") }
        arguments += ["--", path]
        var text = Shell.run("git", arguments, cwd: root, timeout: 20)
        if text.trimmedOrNil() == nil, !staged {
            text = Shell.run(
                "git",
                ["diff", "--no-color", "--no-ext-diff", "--no-index", "/dev/null", path],
                cwd: root, timeout: 20)
        }
        var truncated = false
        if text.utf8.count > patchLimit {
            text = String(text.prefix(patchLimit))
            truncated = true
        }
        return GitPatch(
            path: path, staged: staged, patch: text,
            binary: text.contains("Binary files "), truncated: truncated)
    }

    static func commit(directory: String, hash: String) -> GitCommitDetail? {
        guard let root = root(of: directory), isSafeRevision(hash) else { return nil }
        let unit = "\u{1f}"
        let format = ["%H", "%h", "%s", "%an", "%ae", "%aI", "%D", "%P", "%b"].joined(
            separator: unit)
        let header = Shell.run(
            "git", ["show", "--no-patch", "--no-color", "--format=\(format)", hash], cwd: root,
            timeout: 15)
        let fields = header.components(separatedBy: unit)
        guard fields.count >= 8, let at = isoDate(fields[5]) else { return nil }
        var files: [GitChange] = []
        var byPath: [String: Int] = [:]
        parseNumstat(
            Shell.data(
                "git", ["show", "--numstat", "--format=", "-z", "--no-color", hash], cwd: root,
                timeout: 20)
        ) { path, original, insertions, deletions, binary in
            byPath[path] = files.count
            files.append(
                GitChange(
                    path: path, original: original, index: original == nil ? "M" : "R",
                    binary: binary, insertions: insertions, deletions: deletions))
        }
        applyNameStatus(
            Shell.data(
                "git", ["show", "--name-status", "--format=", "-z", "--no-color", hash], cwd: root,
                timeout: 20), to: &files, byPath: byPath)
        var patch: String? = Shell.run(
            "git", ["show", "--no-color", "--no-ext-diff", "--format=", hash], cwd: root,
            timeout: 25)
        var truncated = false
        if let text = patch, text.utf8.count > patchLimit {
            patch = String(text.prefix(patchLimit))
            truncated = true
        }
        return GitCommitDetail(
            hash: fields[0], short: fields[1], subject: fields[2],
            body: fields.count > 8 ? fields[8].trimmedOrNil() : nil, author: fields[3],
            email: fields[4].trimmedOrNil(), at: at, refs: refs(fields[6]),
            parents: fields[7].split(separator: " ").map(String.init), files: files, patch: patch,
            truncated: truncated)
    }

    private static func parseStatus(_ data: Data, into snapshot: inout GitSnapshot) {
        let records = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard !record.isEmpty else { continue }
            if record.hasPrefix("# ") {
                applyHeader(record, to: &snapshot)
                continue
            }
            switch record.first {
            case "1":
                if let change = ordinaryChange(record) { snapshot.changes.append(change) }
            case "2":
                let original = index < records.count ? records[index] : nil
                index += 1
                if var change = ordinaryChange(record) {
                    change.original = original?.trimmedOrNil()
                    snapshot.changes.append(change)
                }
            case "u":
                if let path = unmergedPath(record) {
                    snapshot.changes.append(
                        GitChange(path: path, index: "U", worktree: "U", conflicted: true))
                }
            case "?":
                let path = String(record.dropFirst(2))
                if !path.isEmpty {
                    snapshot.changes.append(
                        GitChange(
                            path: path, worktree: "?", untracked: true,
                            directory: path.hasSuffix("/")))
                }
            default: continue
            }
        }
    }

    private static func applyHeader(_ record: String, to snapshot: inout GitSnapshot) {
        let fields = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
        guard fields.count == 2 else { return }
        let value = fields[1]
        switch fields[0] {
        case "branch.oid": snapshot.head = value == "(initial)" ? nil : String(value.prefix(8))
        case "branch.head":
            if value == "(detached)" {
                snapshot.detached = true
            } else {
                snapshot.branch = value
            }
        case "branch.upstream": snapshot.upstream = value
        case "branch.ab":
            for part in value.split(separator: " ") {
                let magnitude = Int(part.dropFirst()) ?? 0
                if part.hasPrefix("+") { snapshot.ahead = magnitude }
                if part.hasPrefix("-") { snapshot.behind = magnitude }
            }
        default: return
        }
    }

    private static func ordinaryChange(_ record: String) -> GitChange? {
        let renamed = record.hasPrefix("2")
        let fields = record.split(
            separator: " ", maxSplits: renamed ? 9 : 8, omittingEmptySubsequences: false)
        guard fields.count == (renamed ? 10 : 9) else { return nil }
        let codes = Array(fields[1])
        guard codes.count == 2 else { return nil }
        let path = String(fields[renamed ? 9 : 8])
        guard !path.isEmpty else { return nil }
        return GitChange(
            path: path,
            index: codes[0] == "." ? nil : String(codes[0]),
            worktree: codes[1] == "." ? nil : String(codes[1]),
            submodule: fields[2].first == "S")
    }

    private static func unmergedPath(_ record: String) -> String? {
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { return nil }
        return String(fields[10]).trimmedOrNil()
    }

    private static func applyNumstat(root: String, to snapshot: inout GitSnapshot) {
        var byPath: [String: Int] = [:]
        for (offset, change) in snapshot.changes.enumerated() { byPath[change.path] = offset }
        parseNumstat(
            Shell.data(
                "git", ["diff", "--numstat", "-z", "--no-color", "--no-ext-diff"], cwd: root,
                timeout: 20)
        ) { path, _, insertions, deletions, binary in
            guard let offset = byPath[path] else { return }
            snapshot.changes[offset].insertions = insertions
            snapshot.changes[offset].deletions = deletions
            if binary { snapshot.changes[offset].binary = true }
        }
        parseNumstat(
            Shell.data(
                "git", ["diff", "--cached", "--numstat", "-z", "--no-color", "--no-ext-diff"],
                cwd: root, timeout: 20)
        ) { path, _, insertions, deletions, binary in
            guard let offset = byPath[path] else { return }
            snapshot.changes[offset].stagedInsertions = insertions
            snapshot.changes[offset].stagedDeletions = deletions
            if binary { snapshot.changes[offset].binary = true }
        }
    }

    private static func parseNumstat(
        _ data: Data, _ each: (String, String?, Int, Int, Bool) -> Void
    ) {
        let records = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard !record.isEmpty else { continue }
            let fields = record.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let binary = fields[0] == "-"
            let insertions = Int(fields[0]) ?? 0
            let deletions = Int(fields[1]) ?? 0
            var path = String(fields[2])
            var original: String?
            if path.isEmpty, index + 1 < records.count {
                original = records[index]
                path = records[index + 1]
                index += 2
            }
            guard !path.isEmpty else { continue }
            each(path, original, insertions, deletions, binary)
        }
    }

    private static func applyNameStatus(
        _ data: Data, to files: inout [GitChange], byPath: [String: Int]
    ) {
        let records = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var index = 0
        while index < records.count {
            let code = records[index]
            index += 1
            guard let letter = code.first, code.count <= 4 else { continue }
            let renamed = letter == "R" || letter == "C"
            guard index < records.count else { break }
            let first = records[index]
            index += 1
            var path = first
            if renamed, index < records.count {
                path = records[index]
                index += 1
            }
            guard let offset = byPath[path] else { continue }
            files[offset].index = String(letter)
            if renamed { files[offset].original = first }
        }
    }

    private static func measureUntracked(root: String, in snapshot: inout GitSnapshot) {
        var measured = 0
        for (offset, change) in snapshot.changes.enumerated() where change.untracked {
            guard measured < 200 else { break }
            measured += 1
            let full = root + "/" + change.path
            if change.directory {
                let (files, capped) = countFiles(in: full)
                snapshot.changes[offset].contains = files
                snapshot.changes[offset].containsAtLeast = capped
                continue
            }
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: full),
                let size = attributes[.size] as? Int
            else { continue }
            snapshot.changes[offset].bytes = size
            guard size > 0, size <= 256 * 1024, let data = FileManager.default.contents(atPath: full)
            else { continue }
            if data.contains(0) {
                snapshot.changes[offset].binary = true
                continue
            }
            var lines = data.reduce(into: 0) { total, byte in if byte == 0x0a { total += 1 } }
            if data.last != 0x0a { lines += 1 }
            snapshot.changes[offset].insertions = lines
        }
    }

    private static func countFiles(in directory: String) -> (Int, Bool) {
        guard
            let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return (0, false) }
        var count = 0
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
            if count >= 2000 { return (count, true) }
        }
        return (count, false)
    }

    private static func commits(root: String, limit: Int) -> [GitCommitSummary] {
        let unit = "\u{1f}"
        let record = "\u{1e}"
        let format = ["%H", "%h", "%s", "%an", "%aI", "%D"].joined(separator: unit) + record
        let output = Shell.run(
            "git", ["log", "--no-color", "-n", "\(limit)", "--format=\(format)"], cwd: root,
            timeout: 15)
        return output.components(separatedBy: record).compactMap { entry in
            let fields = entry.trimmingCharacters(in: .whitespacesAndNewlines).components(
                separatedBy: unit)
            guard fields.count >= 6, !fields[0].isEmpty, let at = isoDate(fields[4]) else {
                return nil
            }
            return GitCommitSummary(
                hash: fields[0], short: fields[1], subject: fields[2], author: fields[3], at: at,
                refs: refs(fields[5]))
        }
    }

    private static func operation(root: String) -> String? {
        guard
            let gitDir = Shell.run("git", ["rev-parse", "--absolute-git-dir"], cwd: root)
                .trimmedOrNil()
        else { return nil }
        let manager = FileManager.default
        let states: [(String, String)] = [
            ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
            ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"),
            ("BISECT_LOG", "bisect"),
        ]
        for (marker, name) in states
        where manager.fileExists(atPath: "\(gitDir)/\(marker)") {
            return name
        }
        return nil
    }

    private static func remote(root: String) -> String? {
        if let origin = Shell.run("git", ["remote", "get-url", "origin"], cwd: root, timeout: 10)
            .trimmedOrNil()
        {
            return origin
        }
        guard
            let first = Shell.run("git", ["remote"], cwd: root, timeout: 10)
                .split(separator: "\n").first
        else { return nil }
        return Shell.run("git", ["remote", "get-url", String(first)], cwd: root, timeout: 10)
            .trimmedOrNil()
    }

    private static func fetchedAt(root: String) -> Date? {
        guard
            let gitDir = Shell.run("git", ["rev-parse", "--absolute-git-dir"], cwd: root)
                .trimmedOrNil(),
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: "\(gitDir)/FETCH_HEAD")
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private static func refs(_ raw: String) -> [String] {
        raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private static func isoDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    private static func isSafeRevision(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 100, !raw.hasPrefix("-") else { return false }
        return raw.allSatisfy { $0.isLetter || $0.isNumber || "._-/^~".contains($0) }
    }
}
