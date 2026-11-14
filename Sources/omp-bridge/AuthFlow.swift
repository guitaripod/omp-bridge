import Foundation

struct AuthStatusDTO: Encodable {
    var loggedIn: Bool
    var method: String?
    var email: String?
    var organization: String?
    var subscription: String?
    var pending: PendingLogin?
    var providers: [ProviderDTO]?

    struct PendingLogin: Encodable {
        var url: String
        var startedAt: Date
    }

    struct ProviderDTO: Encodable {
        var id: String
        var name: String?
        var available: Bool
        var authenticated: Bool
    }
}

struct LoginRequest: Codable {
    var provider: String?
}

struct CodeRequest: Codable {
    var code: String
}

actor AuthFlow {
    private let config: Config
    private var loginProcess: OmpProcess?
    private var pendingURL: String?
    private var pendingStartedAt: Date?
    private var lastAuthCheck = Date.distantPast
    private var lastAuthenticated = false
    private var pendingInputID: String?
    private var knownProviders: (providers: [AuthStatusDTO.ProviderDTO], at: Date)?
    private var providerProbe: Task<[AuthStatusDTO.ProviderDTO]?, Never>?
    private var providerGeneration = 0

    init(config: Config) {
        self.config = config
    }

    func isAuthenticatedCached() -> Bool {
        if Date().timeIntervalSince(lastAuthCheck) > 60 {
            lastAuthCheck = Date()
            Task { _ = await checkAuthenticated() }
        }
        return lastAuthenticated
    }

    func checkAuthenticated() async -> Bool {
        let providers = await providerStates()
        lastAuthenticated = providers.contains(where: \.authenticated)
        lastAuthCheck = Date()
        return lastAuthenticated
    }

    func status() async -> AuthStatusDTO {
        if loginProcess != nil { forgetProviders() }
        let providers = await providerStates()
        let loggedIn = providers.contains(where: \.authenticated)
        let pending = pendingURL.map { url in
            AuthStatusDTO.PendingLogin(url: url, startedAt: pendingStartedAt ?? Date())
        }
        return AuthStatusDTO(
            loggedIn: loggedIn || pending != nil,
            method: nil, email: nil, organization: nil, subscription: nil,
            pending: pending,
            providers: providers.isEmpty ? nil : providers)
    }

    func startLogin(provider wanted: String?) async throws -> AuthStatusDTO {
        await cancelLogin()
        let process = OmpProcess(
            ompBin: config.ompBin, directory: config.workdir
        ) { [weak self] frame in
            await self?.handleFrame(frame)
        }
        try await process.start()
        loginProcess = process
        let startedAt = Date()
        pendingStartedAt = startedAt
        abandon(loginStartedAt: startedAt)
        if let wanted, !wanted.isEmpty {
            _ = await process.request("login", fields: ["providerId": wanted], timeout: 20)
        } else {
            let providers = await providerStates()
            let target =
                providers.first(where: \.authenticated)?.id
                ?? providers.first(where: { $0.id == "anthropic" })?.id
                ?? providers.first?.id
            if let target {
                _ = await process.request("login", fields: ["providerId": target], timeout: 20)
            }
        }
        for _ in 0..<50 {
            if pendingURL != nil {
                return await status()
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await status()
    }

    private func handleFrame(_ frame: JSONValue) async {
        guard frame["type"]?.stringValue == "extension_ui_request" else { return }
        let method = frame["method"]?.stringValue
        if method == "input", let id = frame["id"]?.stringValue {
            pendingInputID = id
        }
        guard method == "open_url" else { return }
        if let raw = frame["url"]?.stringValue {
            var cleaned = raw
            if let range = cleaned.range(of: "url=") {
                cleaned = String(cleaned[range.upperBound...])
                cleaned = cleaned.removingPercentEncoding ?? cleaned
            }
            pendingURL = cleaned
        }
    }

    func submitCode(_ code: String) async throws -> AuthStatusDTO {
        guard let process = loginProcess, let requestID = pendingInputID else {
            throw BridgeError.badRequest("This sign-in flow does not need a code")
        }
        _ = await process.sendExternal([
            "id": requestID, "type": "extension_ui_response", "value": code,
        ])
        pendingInputID = nil
        forgetProviders()
        return await status()
    }

    func cancelLogin() async {
        await loginProcess?.stop()
        loginProcess = nil
        pendingURL = nil
        pendingStartedAt = nil
        pendingInputID = nil
        forgetProviders()
    }

    /// A sign-in nobody finished holds a whole engine open; it is let go once it has waited
    /// ``loginPatience``, unless a newer sign-in has replaced it by then.
    private func abandon(loginStartedAt startedAt: Date) {
        Task {
            try? await Task.sleep(for: .seconds(Self.loginPatience))
            guard pendingStartedAt == startedAt else { return }
            await cancelLogin()
        }
    }

    private static let loginPatience: TimeInterval = 15 * 60

    /// How long a reading of the login providers is trusted. Asking costs a whole engine start, a
    /// second of a core and a few hundred megabytes, and every chat a client opens asks; a sign-in
    /// made through this bridge forgets the reading at once, and one made in a terminal shows
    /// within this long.
    private static let providersFresh: TimeInterval = 5 * 60

    private func forgetProviders() {
        knownProviders = nil
        providerGeneration += 1
    }

    /// The auth probe only asks omp for its login providers, so it starts omp without skills:
    /// with them, every start sends each uncached skill description to the `smol` model to
    /// compress, and a probe that runs every minute and exits before the answers land keeps
    /// cold-starting that model on the GPU for nothing.
    static let probeArguments = ["--no-skills"]

    /// The login providers as last read, read again once the reading is older than
    /// ``providersFresh``. Callers asking at the same moment share one engine start, and a probe
    /// that fails keeps the last good reading rather than calling a signed-in machine signed out.
    private func providerStates() async -> [AuthStatusDTO.ProviderDTO] {
        if let known = knownProviders, Date().timeIntervalSince(known.at) < Self.providersFresh {
            return known.providers
        }
        let probe: Task<[AuthStatusDTO.ProviderDTO]?, Never>
        if let running = providerProbe {
            probe = running
        } else {
            probe = Task { await self.probeProviders() }
            providerProbe = probe
        }
        let generation = providerGeneration
        let fresh = await probe.value
        providerProbe = nil
        if let fresh, generation == providerGeneration {
            knownProviders = (fresh, Date())
        }
        return fresh ?? knownProviders?.providers ?? []
    }

    private func probeProviders() async -> [AuthStatusDTO.ProviderDTO]? {
        let probe = OmpProcess(
            ompBin: config.ompBin, directory: config.workdir, arguments: Self.probeArguments
        ) { _ in }
        do {
            try await probe.start()
        } catch {
            return nil
        }
        let response = await probe.request("get_login_providers", timeout: 20)
        defer { Task { await probe.stop() } }
        guard response.success, let list = response.data?["providers"]?.arrayValue else { return nil }
        return list.compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            return AuthStatusDTO.ProviderDTO(
                id: id, name: entry["name"]?.stringValue,
                available: entry["available"]?.boolValue ?? true,
                authenticated: entry["authenticated"]?.boolValue ?? false)
        }
    }
}
