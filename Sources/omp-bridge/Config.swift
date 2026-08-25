import Foundation

struct Config: Sendable {
    let port: Int
    let bind: String
    let password: String
    let workdir: String
    let ompBin: String
    let storePath: String
    let stateDir: String
    let srcPath: String?
    let defaultModel: String?
    let defaultEffort: String

    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        @Sendable func path(_ name: String, _ fallback: String) -> String {
            let raw = env[name] ?? ""
            return raw.isEmpty ? fallback : NSString(string: raw).expandingTildeInPath
        }
        let stateDir = path("OMP_STATE_DIR", home + "/.omp-bridge")
        let storePath = path("OMP_STORE", stateDir + "/sessions.json")
        let resolvedState = env["OMP_STATE_DIR"] == nil ? (storePath as NSString).deletingLastPathComponent : stateDir
        try? FileManager.default.createDirectory(atPath: resolvedState, withIntermediateDirectories: true)
        let workdir = path("OMP_WORKDIR", home + "/.omp-bridge/workdir")
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        var src = env["OMP_SRC"] ?? ""
        if src.isEmpty { src = currentCheckoutRoot() ?? "" }
        return Config(
            port: Int(env["OMP_PORT"] ?? "") ?? 4099,
            bind: env["OMP_BIND"] ?? "127.0.0.1",
            password: env["OMP_PASSWORD"] ?? "",
            workdir: workdir,
            ompBin: path("OMP_BIN", "/usr/local/bin/omp"),
            storePath: storePath,
            stateDir: resolvedState,
            srcPath: src.isEmpty ? nil : src,
            defaultModel: env["OMP_MODEL"].flatMap { $0.isEmpty ? nil : $0 },
            defaultEffort: env["OMP_EFFORT"] ?? "medium"
        )
    }

    private static func currentCheckoutRoot() -> String? {
        let exe = CommandLine.arguments[0]
        var url = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
        for _ in 0..<6 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
        }
        return nil
    }

    var ompSessionsRoot: String {
        NSString(string: "~/.omp/agent/sessions").expandingTildeInPath
    }

    var attachmentsDir: String {
        stateDir + "/attachments"
    }
}
