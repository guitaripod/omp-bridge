import Foundation
import Hummingbird

func env(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
}

let config = Config.load()
if config.password.isEmpty, FileManager.default.fileExists(atPath: config.ompBin) {
    let stderr = FileHandle.standardError
    stderr.write(
        Data(
            """
            omp-bridge: refusing to start.

            OMP_PASSWORD is empty. oh-my-pi runs with full tool permissions by default,
            so any client that can reach this server can execute arbitrary shell
            commands as this user, with no authentication.

            Fix: set OMP_PASSWORD to a secret (systemd: ~/.config/omp-bridge.env).
            Clients authenticate with HTTP Basic auth (username "omp").

            """.utf8))
    exit(1)
}
if !FileManager.default.isExecutableFile(atPath: config.ompBin) {
    FileHandle.standardError.write(
        Data("omp-bridge: omp binary not found or not executable at \(config.ompBin)\n".utf8))
    exit(1)
}

let app = App(config: config)
await app.prepare()

let router = Router()
if !config.password.isEmpty {
    router.middlewares.add(BasicAuthMiddleware(password: config.password))
}
await registerRoutes(router, app: app, config: config)

Task { await app.runObserver() }
Task { await app.runHeartbeats() }

let quietRegistry = app.quietRegistry
let updateService = app.updateService
await updateService.attach(
    quiet: {
        let machineQuiet = await quietRegistry.read()
        return MachineQuiet.read(turns: machineQuiet.turns)
    },
    settle: { await app.flushAll() })
await updateService.resume()
await updateService.startAutomation()

let service = Application(
    router: router,
    configuration: .init(address: .hostname(config.bind, port: config.port), serverName: "omp-bridge"))

print("omp-bridge listening on \(config.bind):\(config.port) — workdir \(config.workdir), omp \(config.ompBin)")
do {
    try await service.runService()
} catch {
    await app.shutdown()
    throw error
}

/// Basic auth that verifies only the password. The username carries no secret — it is a client-side
/// convention that names which bridge a profile thinks it is talking to ("omp", "claude",
/// "opencode"), and clients shipped before this bridge existed retry with the wrong one. Rejecting
/// a correct password over a label locks those clients out for nothing.
struct BasicAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    private let password: String

    init(password: String) {
        self.password = password
    }

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard suppliedPassword(request) == password else {
            var headers = HTTPFields()
            headers[.wwwAuthenticate] = "Basic realm=\"omp-bridge\""
            return Response(status: .unauthorized, headers: headers)
        }
        return try await next(request, context)
    }

    private func suppliedPassword(_ request: Request) -> String? {
        guard let header = request.headers[.authorization],
            header.hasPrefix("Basic "),
            let decoded = Data(base64Encoded: String(header.dropFirst(6))),
            let pair = String(data: decoded, encoding: .utf8),
            let separator = pair.firstIndex(of: ":")
        else { return nil }
        return String(pair[pair.index(after: separator)...])
    }
}
