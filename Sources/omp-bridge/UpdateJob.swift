import Foundation

/// One update or restart, from the press to the way it ended.
///
/// The phase file was the only record, and it could never say whose `succeeded` it held or what
/// the machine had landed on: a client following a press read the same word for its own update and
/// for last week's, and nothing survived the restart except that word. A job has an identity, the
/// step it is on, and an outcome written by the process that came back — so a client follows
/// exactly the job it started, picks up one another device or the machine's own policy started,
/// and says what the machine became.
///
/// It lives in its own file because the installer rewrites the phase file whole on every step, and
/// anything kept beside the phase would be erased by the script it describes.
struct UpdateJob: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case update
        case restart
    }

    enum Step: String, Codable, Sendable {
        case download
        case build
        case waitForIdle
        case restart
        case done
    }

    enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        /// The build is on the machine and only the loading of it is owed.
        case deferred
    }

    var id: String
    var kind: Kind
    var automatic: Bool
    var step: Step
    var outcome: Outcome?
    var from: String?
    var target: String?
    var landed: String?
    var reason: String?
    var startedAt: Date
    var stepStartedAt: Date
    var finishedAt: Date?

    static func begin(
        _ kind: Kind, automatic: Bool, from: String?, target: String?, now: Date = Date()
    ) -> UpdateJob {
        UpdateJob(
            id: UUID().uuidString, kind: kind, automatic: automatic,
            step: kind == .update ? .download : .waitForIdle, outcome: nil, from: from,
            target: target, landed: nil, reason: nil, startedAt: now, stepStartedAt: now,
            finishedAt: nil)
    }

    var isFinished: Bool { outcome != nil }

    /// Moves to a later step. A step never goes backwards and a finished job never moves: a poll
    /// that reads a stale phase after the job ended must not reopen it.
    mutating func advance(to next: Step, now: Date = Date()) {
        guard !isFinished, next.order > step.order else { return }
        step = next
        stepStartedAt = now
    }

    mutating func finish(_ outcome: Outcome, reason: String? = nil, landed: String? = nil, now: Date = Date()) {
        guard !isFinished else { return }
        self.outcome = outcome
        self.reason = reason
        self.landed = landed
        if outcome == .succeeded { step = .done }
        finishedAt = now
    }

    /// What a process that has just started concludes about the job that was in flight when the
    /// last one stopped.
    ///
    /// The question is whether the build now running is one the job made, and the evidence is the
    /// build stamp the installer writes after every build — not the binary's own date, which an
    /// update that changed no source leaves exactly where it was. An update landed when the running
    /// build was stamped after the job began. A restart landed when this process started after it,
    /// and when no newer build is still waiting on disk, which would mean the restart loaded
    /// something other than what was owed.
    static func conclusion(
        of job: UpdateJob, runningBuiltAt: Date?, processStarted: Date, restartStillOwed: Bool
    ) -> (Outcome, String?) {
        switch job.kind {
        case .update:
            guard let built = runningBuiltAt else {
                return (.succeeded, nil)
            }
            guard built >= job.startedAt.addingTimeInterval(-OmpVersion.stampSlack) else {
                if job.step == .download || job.step == .build {
                    return (
                        .failed,
                        "The bridge restarted before the build finished, so it is still on the "
                            + "build it had."
                    )
                }
                return (.failed, "The bridge came back on the build it already had.")
            }
            return (.succeeded, nil)
        case .restart:
            guard processStarted >= job.startedAt else {
                return (.failed, "The bridge did not restart.")
            }
            guard !restartStillOwed else {
                return (.failed, "The bridge restarted, and a newer build is still waiting on disk.")
            }
            return (.succeeded, nil)
        }
    }
}

extension UpdateJob.Step {
    var order: Int {
        switch self {
        case .download: return 0
        case .build: return 1
        case .waitForIdle: return 2
        case .restart: return 3
        case .done: return 4
        }
    }

    /// The step the installer's own phase word stands for. The script writes the phase file and
    /// nothing else, so the job learns where the build has got to by reading it.
    init?(installerPhase: String) {
        switch installerPhase {
        case "running": self = .download
        case "building": self = .build
        case "waiting": self = .waitForIdle
        case "restarting": self = .restart
        default: return nil
        }
    }
}

/// The last line the installer wrote about why it stopped. The script prefixes every refusal with
/// `error:`, and that line is a sentence meant for a person — "only 900 MB free where the checkout
/// lives" — where the tail of a Swift build is not.
enum InstallerLog {
    static func failure(in log: String?) -> String? {
        guard let log else { return nil }
        guard
            let line = log.split(separator: "\n").reversed()
                .first(where: { $0.hasPrefix("error: ") })
        else { return nil }
        let reason = line.dropFirst("error: ".count).trimmingCharacters(in: .whitespaces)
        guard let first = reason.first else { return nil }
        return first.uppercased() + reason.dropFirst()
    }
}

/// What a newer build carries, written for people.
///
/// A commit count is not news and a commit subject in this project is a paragraph. The project
/// keeps a changelog of short lines per release, so what the machine would move to is read from
/// the changelog *at the project's head* — the one the update would bring — and only the releases
/// newer than what is running are reported. Where the changelog has nothing to say, the commits'
/// own headlines stand in.
struct UpdateRelease: Codable, Sendable, Equatable {
    struct Note: Codable, Sendable, Equatable {
        var version: String?
        var date: String?
        var items: [String]
    }

    var version: String?
    var commitsPastTag: Int?
    var notes: [Note]

    static let noteLimit = 6
    static let itemLimit = 10

    /// Assembles the notes from what git said. Kept apart from git so it can be read and tested.
    static func assemble(
        changelog: String?, running: String?, tag: String?, commitsPastTag: Int?,
        untaggedSubjects: [String], newSubjects: [String]
    ) -> UpdateRelease {
        let base = ReleaseVersion(running ?? "")
        let sections = Changelog.parse(changelog ?? "")
        var notes: [Note] = []
        if (commitsPastTag ?? 0) > 0 {
            if let unreleased = sections.first(where: { $0.version == nil }), !unreleased.items.isEmpty {
                notes.append(unreleased)
            } else if !untaggedSubjects.isEmpty {
                notes.append(Note(version: nil, date: nil, items: untaggedSubjects.map(CommitHeadline.short)))
            }
        }
        for section in sections {
            guard let version = section.version, let parsed = ReleaseVersion(version) else { continue }
            guard let base else {
                notes.append(section)
                continue
            }
            if base.isOlder(than: parsed) { notes.append(section) }
        }
        if notes.isEmpty, !newSubjects.isEmpty {
            notes.append(
                Note(
                    version: (commitsPastTag ?? 0) == 0 ? tag : nil, date: nil,
                    items: newSubjects.map(CommitHeadline.short)))
        }
        let trimmed = notes.prefix(noteLimit).map {
            Note(version: $0.version, date: $0.date, items: Array($0.items.prefix(itemLimit)))
        }
        return UpdateRelease(version: tag, commitsPastTag: commitsPastTag, notes: Array(trimmed))
    }
}

/// The project's `CHANGELOG.md`: `## 1.10.0 — 2026-09-23` headings over `- ` bullets, with an
/// optional `## Unreleased` section for what is past the newest tag.
enum Changelog {
    static func parse(_ text: String) -> [UpdateRelease.Note] {
        var notes: [UpdateRelease.Note] = []
        var current: UpdateRelease.Note?
        var item: String?

        func closeItem() {
            if let text = item?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                current?.items.append(text)
            }
            item = nil
        }

        func closeSection() {
            closeItem()
            if let section = current { notes.append(section) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                closeSection()
                current = heading(String(line.dropFirst(3)))
                continue
            }
            guard current != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                closeItem()
                item = String(trimmed.dropFirst(2))
            } else if trimmed.isEmpty {
                closeItem()
            } else if item != nil, line.first == " " || line.first == "\t" {
                item! += " " + trimmed
            }
        }
        closeSection()
        return notes
    }

    private static func heading(_ text: String) -> UpdateRelease.Note {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        }
        let version = words.first(where: { ReleaseVersion($0) != nil })
        let date = words.first(where: isDate)
        return UpdateRelease.Note(
            version: version.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }, date: date,
            items: [])
    }

    private static func isDate(_ word: String) -> Bool {
        let parts = word.split(separator: "-")
        return parts.count == 3 && parts[0].count == 4 && parts.allSatisfy { Int($0) != nil }
    }
}

/// The dotted numbers of a release, read out of a tag or out of `git describe`.
struct ReleaseVersion: Equatable {
    let components: [Int]

    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        guard let numbers = body.split(separator: "-").first, numbers.contains(".") else {
            return nil
        }
        let parsed = numbers.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        components = parsed.compactMap { $0 }
    }

    func isOlder(than other: ReleaseVersion) -> Bool {
        for index in 0..<max(components.count, other.components.count) {
            let left = index < components.count ? components[index] : 0
            let right = index < other.components.count ? other.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// The headline a commit subject leads with.
///
/// This project writes a commit's subject as its whole argument — a claim, a colon, and a
/// paragraph proving it — so the claim is the part worth listing, and the paragraph is not.
enum CommitHeadline {
    static let limit = 110

    static func short(_ subject: String) -> String {
        let text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [": ", " — ", ". ", "; "] {
            if let range = text.range(of: separator) {
                let head = String(text[..<range.lowerBound])
                if head.count >= 12, head.count <= limit { return capitalized(head) }
            }
        }
        guard text.count > limit else { return capitalized(text) }
        let cut = text.prefix(limit)
        let clean = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return capitalized(clean) + "…"
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
