import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import ServiceLifecycle

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? WireCoding.encoder.encode(value)) ?? Data("{}".utf8)
    var buffer = ByteBuffer()
    buffer.writeBytes(data)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
}

private func errorResponse(_ message: String, status: HTTPResponse.Status) -> Response {
    let data = (try? WireCoding.encoder.encode(["error": message])) ?? Data("{}".utf8)
    var buffer = ByteBuffer()
    buffer.writeBytes(data)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
}

struct SendAccepted: Encodable {
    let ok = true
    let queued: Bool
    let position: Int?
}

struct InterruptionRefusedDTO: Encodable {
    static let nothingInterrupted = "nothing_interrupted"
    static let alreadyResumed = "already_resumed"
    static let unknownSession = "unknown_session"

    let error: String
    let reason: String
    let interruption: Interruption?

    private enum CodingKeys: String, CodingKey { case error, reason, interruption }
}

struct ResumeAcceptedDTO: Encodable {
    let ok = true
    let queued: Bool
    let position: Int?
    let interruption: Interruption?
}

struct AbortResultDTO: Encodable {
    let ok = true
    let stopped: Bool
    let discarded: Int
}

private func rawResponse(
    _ data: Data, mime: String?, cacheControl: String = "private, max-age=60"
) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = mime
    headers[.cacheControl] = cacheControl
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: buffer))
}

private func fileResponse(
    path: String, size: Int, mime: String?, cacheControl: String = "private, max-age=60"
) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = mime
    headers[.cacheControl] = cacheControl
    headers[.contentLength] = String(size)
    let stream = ResponseBody { writer in
        guard let handle = FileHandle(forReadingAtPath: path) else {
            try await writer.finish(nil)
            return
        }
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            try await writer.write(buffer)
        }
        try await writer.finish(nil)
    }
    return Response(status: .ok, headers: headers, body: stream)
}

private func decodeBody<T: Decodable>(
    _ type: T.Type, _ request: Request, limit: Int = 1 << 20
) async throws -> T {
    let buffer = try await request.body.collect(upTo: limit)
    return try WireCoding.decoder.decode(T.self, from: Data(buffer.readableBytesView))
}

func registerRoutes(_ router: Router<BasicRequestContext>, app: App, config: Config) async {

    // MARK: handshake

    router.get("health") { _, _ in "ok" }

    router.get("status") { _, _ in
        jsonResponse(await app.statusPayload())
    }

    router.get("stream") { request, _ in
        var sinceEpoch: String?
        var sinceSeq: UInt64?
        let sinceParam = request.uri.queryParameters.get("since").map { String($0) }
        let cursor =
            request.headers[.init("Last-Event-ID")!].flatMap { $0.isEmpty ? nil : $0 }
            ?? sinceParam
        if let cursor {
            let parts = cursor.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let seq = UInt64(parts[1]) {
                sinceEpoch = String(parts[0])
                sinceSeq = seq
            }
        }
        let attachment = await app.hubAttachment(sinceEpoch: sinceEpoch, sinceSeq: sinceSeq)
        let epoch = await app.hubEpoch()
        let oldest = await app.oldestReplayableSeqValue()

        let body = ResponseBody { writer in
            func writeFrame(seq: UInt64?, event: String, json: Data) async throws {
                var buffer = ByteBuffer()
                if let seq { buffer.writeString("id: \(epoch):\(seq)\n") }
                buffer.writeString("event: \(event)\ndata: ")
                buffer.writeBytes(json)
                buffer.writeString("\n\n")
                try await writer.write(buffer)
            }
            func encode<Value: Encodable>(_ value: Value) -> Data {
                (try? WireCoding.encoder.encode(value)) ?? Data("{}".utf8)
            }
            func writeHub(_ frame: HubFrame) async throws {
                switch frame.event {
                case .session(let id, let event):
                    let payload = SessionFramePayload(session: id, event: event)
                    try await writeFrame(seq: frame.seq, event: "session", json: encode(payload))
                case .listUpsert(let summary):
                    try await writeFrame(seq: frame.seq, event: "list.upsert", json: encode(summary))
                case .listRemove(let id):
                    try await writeFrame(seq: frame.seq, event: "list.remove", json: encode(["id": id]))
                case .agents(let sessionID, let agents):
                    let payload = AgentsFramePayload(session: sessionID, agents: agents)
                    try await writeFrame(seq: frame.seq, event: "agents", json: encode(payload))
                case .heartbeat(let seq):
                    try await writeFrame(
                        seq: nil, event: "heartbeat", json: encode(Heartbeat(seq: seq, t: Date())))
                }
            }

            let hello = StreamHello(
                proto: 2, epoch: epoch, seq: attachment.headSeq, oldestSeq: oldest,
                heartbeat: 10, reset: attachment.tooOld)
            try await writeFrame(seq: attachment.headSeq, event: "hello", json: encode(hello))
            for frame in attachment.replay { try await writeHub(frame) }

            try await withGracefulShutdownHandler {
                for await frame in attachment.stream {
                    try await writeHub(frame)
                }
            } onGracefulShutdown: {
                Task { await app.detachHub(id: attachment.id) }
            }
            await app.detachHub(id: attachment.id)
            try await writer.finish(nil)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: auth

    router.get("auth") { _, _ in
        jsonResponse(await app.authFlow.status())
    }

    router.post("auth/login") { request, _ in
        let wanted = try? await decodeBody(LoginRequest.self, request).provider
        do {
            return jsonResponse(try await app.authFlow.startLogin(provider: wanted))
        } catch {
            return errorResponse(error.localizedDescription, status: .badGateway)
        }
    }

    router.post("auth/code") { request, _ in
        let code = (try? await decodeBody(CodeRequest.self, request).code) ?? ""
        do {
            return jsonResponse(try await app.authFlow.submitCode(code))
        } catch {
            return errorResponse(error.localizedDescription, status: .badRequest)
        }
    }

    router.post("auth/cancel") { _, _ in
        await app.authFlow.cancelLogin()
        return jsonResponse(["ok": true])
    }

    // MARK: update

    router.get("update") { request, _ in
        let checkOnly = request.uri.queryParameters.get("check") == "false"
        return jsonResponse(await app.updateStatus(refreshing: !checkOnly))
    }

    router.post("update") { _, _ in
        let (accepted, status) = await app.startUpdate()
        return accepted
            ? jsonResponse(status, status: .accepted)
            : errorResponse(status.reason ?? "This machine cannot update itself", status: .conflict)
    }

    router.post("update/restart") { _, _ in
        let restarted = await app.restartUpdate()
        let (accepted, status) = restarted
        return accepted
            ? jsonResponse(status, status: .accepted)
            : errorResponse(status.reason ?? "Nothing to restart into", status: .conflict)
    }

    router.post("update/auto") { request, _ in
        let enabled = (try? await decodeBody(AutoResumeRequest.self, request).enabled) ?? false
        return jsonResponse(await app.updateService.setAutomation(enabled: enabled))
    }

    // MARK: sessions

    router.get("sessions") { _, _ in
        let summaries = Array((await app.currentSummaries()).values)
            .sorted { $0.updatedAt > $1.updatedAt }
        return jsonResponse(summaries)
    }

    router.post("sessions") { request, _ in
        let body = (try? await decodeBody(CreateRequest.self, request)) ?? CreateRequest(
            title: nil, directory: nil, model: nil, effort: nil)
        let session = await app.createSession(
            title: body.title, directory: body.directory, model: body.model, effort: body.effort)
        return jsonResponse(await sessionSnapshot(session), status: .created)
    }

    router.get("search") { request, _ in
        guard let query = request.uri.queryParameters.get("q"), !query.isEmpty else {
            return errorResponse("No query given", status: .badRequest)
        }
        let limit = min(Int(request.uri.queryParameters.get("limit") ?? "") ?? 40, 200)
        let response = await TranscriptSearch.search(
            root: config.ompSessionsRoot, query: query, limit: limit)
        return jsonResponse(response)
    }

    router.get("models") { _, _ in
        jsonResponse(await app.modelCatalog())
    }

    router.get("commands") { request, _ in
        if let sessionID = request.uri.queryParameters.get("session"),
            let session = await app.liveSession(id: sessionID)
        {
            return jsonResponse(await session.commandCatalog())
        }
        let directory = request.uri.queryParameters.get("directory").map { String($0) }
        return jsonResponse(await app.commandCatalog(directory: directory))
    }

    router.get("analytics") { request, _ in
        let days = Int(request.uri.queryParameters.get("days") ?? "") ?? 30
        var live: [OmpSession] = []
        for sessionID in await app.liveSessionIDs() {
            if let session = await app.liveSession(id: sessionID) { live.append(session) }
        }
        let report = await AnalyticsBuilder.build(config: config, liveSessions: live, days: days)
        return jsonResponse(report)
    }

    router.get("files") { request, _ in
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = request.uri.queryParameters.get("path") ?? "."
        let path = FileBrowsing.resolve(raw, home: home)
        guard let entries = FileBrowsing.list(path) else {
            return errorResponse("not a directory", status: .notFound)
        }
        return jsonResponse(entries)
    }

    router.get("files/content") { request, _ in
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = request.uri.queryParameters.get("path") ?? ""
        guard !raw.isEmpty else { return errorResponse("No path given", status: .badRequest) }
        let path = FileBrowsing.resolve(raw, home: home)
        guard let content = FileBrowsing.content(path) else {
            return errorResponse("not readable", status: .notFound)
        }
        return jsonResponse(FileContent(path: path, content: content))
    }

    router.get("files/raw") { request, _ in
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let raw = request.uri.queryParameters.get("path") else {
            return errorResponse("No path given", status: .badRequest)
        }
        let path = FileBrowsing.resolve(raw, home: home)
        guard let size = FileBrowsing.readableSize(path) else {
            return errorResponse("not readable", status: .notFound)
        }
        let ext = (path as NSString).pathExtension
        return fileResponse(path: path, size: size, mime: mimeType(forExtension: ext))
    }

    router.get("git") { request, _ in
        guard let dir = await resolveGitDirectory(request, app: app) else {
            return errorResponse("No directory given", status: .badRequest)
        }
        guard let snapshot = Git.snapshot(directory: dir) else {
            return errorResponse("This server cannot say", status: .notFound)
        }
        return jsonResponse(snapshot)
    }

    router.get("git/diff") { request, _ in
        guard let path = request.uri.queryParameters.get("path"),
            let dir = await resolveGitDirectory(request, app: app)
        else { return errorResponse("No path given", status: .badRequest) }
        let staged = request.uri.queryParameters.get("staged") == "true"
        guard let patch = Git.patch(directory: dir, path: path, staged: staged) else {
            return errorResponse("not readable", status: .notFound)
        }
        return jsonResponse(patch)
    }

    router.get("git/commit") { request, _ in
        guard let hash = request.uri.queryParameters.get("hash"),
            let dir = await resolveGitDirectory(request, app: app),
            let detail = Git.commit(directory: dir, hash: hash)
        else { return errorResponse("not found", status: .notFound) }
        return jsonResponse(detail)
    }

    router.get("attachments/:session/:name") { _, context in
        let session = context.parameters.get("session") ?? ""
        let name = context.parameters.get("name") ?? ""
        guard session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
            !name.hasPrefix(".")
        else { return errorResponse("not found", status: .notFound) }
        let path = "\(config.attachmentsDir)/\(session)/\(name)"
        guard let size = FileBrowsing.readableSize(path) else {
            return errorResponse("not found", status: .notFound)
        }
        return fileResponse(
            path: path, size: size, mime: mimeType(forExtension: (name as NSString).pathExtension),
            cacheControl: "private, max-age=31536000, immutable")
    }

    router.post("push/device") { _, _ in
        errorResponse("Push notifications are not supported by this bridge", status: .notImplemented)
    }

    router.post("push/device/unregister") { _, _ in
        errorResponse("Push notifications are not supported by this bridge", status: .notImplemented)
    }

    router.post("sessions/:id/live-activity") { _, _ in
        errorResponse("Live Activities are not supported by this bridge", status: .notImplemented)
    }

    router.get("usage") { _, _ in
        errorResponse("Plan gauges are not available for oh-my-pi", status: .notFound)
    }

    router.get("usage/grok") { _, _ in
        errorResponse("Plan gauges are not available for oh-my-pi", status: .notFound)
    }

    router.get("usage/opencode") { _, _ in
        errorResponse("Plan gauges are not available for oh-my-pi", status: .notFound)
    }

    // MARK: one session

    @Sendable func resolveSession(_ context: BasicRequestContext) async throws -> OmpSession {
        let id = context.parameters.get("id") ?? ""
        if let live = await app.liveSession(id: id) { return live }
        if let adopted = await app.adoptDiscovered(id: id) { return adopted }
        throw BridgeError.notFound("not found")
    }

    @Sendable func sessionError(_ error: Error) -> Response {
        switch error {
        case BridgeError.notFound(let message):
            return errorResponse(message, status: .notFound)
        case BridgeError.conflict(let message):
            return errorResponse(message, status: .conflict)
        case BridgeError.badRequest(let message):
            return errorResponse(message, status: .badRequest)
        default:
            return errorResponse(error.localizedDescription, status: .internalServerError)
        }
    }

    router.get("sessions/:id") { _, context in
        do {
            let session = try await resolveSession(context)
            return jsonResponse(await sessionSnapshot(session))
        } catch { return sessionError(error) }
    }

    router.patch("sessions/:id") { request, context in
        do {
            let session = try await resolveSession(context)
            let body = try await decodeBody(RenameRequest.self, request)
            await session.rename(body.title)
            return jsonResponse(["ok": true])
        } catch { return sessionError(error) }
    }

    router.delete("sessions/:id") { _, context in
        let id = context.parameters.get("id") ?? ""
        await app.deleteSession(id: id)
        return jsonResponse(["ok": true])
    }

    router.post("sessions/:id/message") { request, context in
        do {
            let session = try await resolveSession(context)
            let body = try await decodeBody(SendRequest.self, request, limit: 32 << 20)
            var promptText = body.text
            let displayText = body.text
            var files: [FileRef] = []
            if let attachments = body.attachments, !attachments.isEmpty {
                files = saveAttachments(attachments, sessionID: context.parameters.get("id") ?? "")
                let lines = files.map { ref in
                    "Attached image (use the Read tool to view it): \(ref.path)"
                }
                promptText = ([body.text] + lines).joined(separator: "\n")
            }
            let accepted = try await session.send(
                text: promptText, displayText: displayText,
                model: body.model, effort: body.effort, attachments: files)
            return jsonResponse(
                SendAccepted(queued: accepted.queued, position: accepted.position),
                status: .accepted)
        } catch { return sessionError(error) }
    }

    router.post("sessions/:id/abort") { _, context in
        do {
            let session = try await resolveSession(context)
            let stopped = await session.abort()
            return jsonResponse(AbortResultDTO(stopped: stopped, discarded: 0))
        } catch { return sessionError(error) }
    }

    router.post("sessions/:id/clear") { _, context in
        do {
            let session = try await resolveSession(context)
            try await session.clear()
            return jsonResponse(["ok": true])
        } catch { return sessionError(error) }
    }

    router.post("sessions/:id/fork") { _, context in
        do {
            let id = context.parameters.get("id") ?? ""
            let session = try await app.forkSession(id: id)
            return jsonResponse(await sessionSnapshot(session))
        } catch { return sessionError(error) }
    }

    router.get("sessions/:id/usage") { _, context in
        do {
            let session = try await resolveSession(context)
            let last = await session.lastTurnCost()
            return jsonResponse(
                UsageSummary(costUSD: last?.costUSD, tokens: last?.tokens))
        } catch { return sessionError(error) }
    }

    router.get("sessions/:id/spend") { _, context in
        do {
            let session = try await resolveSession(context)
            let turns = await session.turnsSnapshot()
            let totals = await session.spendTotalsSnapshot()
            return jsonResponse(
                SpendAnalytics.report(title: await session.titleText(), turns: turns, totals: totals))
        } catch { return sessionError(error) }
    }

    router.get("sessions/:id/interruption") { _, context in
        let id = context.parameters.get("id") ?? ""
        let interruption = await app.interruption(for: id)
        return jsonResponse(["interruption": Optional(interruption)])
    }

    @Sendable func pickBackUp(_: Request, _ context: BasicRequestContext) async throws -> Response {
        let id = context.parameters.get("id") ?? ""
        let known = await app.knowsSession(id: id)
        let heldInterruption = await app.interruption(for: id)
        guard known || heldInterruption != nil else {
            return jsonResponse(
                InterruptionRefusedDTO(
                    error: "Unknown session", reason: InterruptionRefusedDTO.unknownSession,
                    interruption: nil),
                status: .notFound)
        }
        do {
            try await app.resumeInterrupted(id: id)
            let interruption = await app.interruption(for: id)
            return jsonResponse(
                ResumeAcceptedDTO(queued: false, position: nil, interruption: interruption),
                status: .accepted)
        } catch BridgeError.conflict(let message) {
            let interruption = await app.interruption(for: id)
            let reason =
                message.contains("already") ? InterruptionRefusedDTO.alreadyResumed : InterruptionRefusedDTO.nothingInterrupted
            return jsonResponse(
                InterruptionRefusedDTO(
                    error: message, reason: reason, interruption: interruption),
                status: .conflict)
        }
    }

    router.post("sessions/:id/resume", use: pickBackUp)
    router.post("sessions/:id/interruption/resume", use: pickBackUp)

    router.post("sessions/:id/interruption/dismiss") { _, context in
        let id = context.parameters.get("id") ?? ""
        let dismissed = await app.dismissInterruption(id: id)
        if dismissed { return jsonResponse(["ok": true]) }
        return jsonResponse(
            InterruptionRefusedDTO(
                error: "Nothing interrupted here",
                reason: InterruptionRefusedDTO.nothingInterrupted,
                interruption: nil),
            status: .conflict)
    }

    router.post("sessions/:id/auto-resume") { _, context in
        do {
            let session = try await resolveSession(context)
            await session.setAutoResume(true)
            return jsonResponse(["ok": true])
        } catch { return sessionError(error) }
    }

    router.get("sessions/:id/agents") { _, context in
        do {
            let session = try await resolveSession(context)
            return jsonResponse(await session.subagentSummaries())
        } catch { return sessionError(error) }
    }

    router.get("sessions/:id/agents/:agentID") { _, context in
        do {
            let session = try await resolveSession(context)
            let agentID = context.parameters.get("agentID") ?? ""
            guard let transcript = await session.subagentTranscript(agentID: agentID) else {
                return errorResponse("not found", status: .notFound)
            }
            return jsonResponse(transcript)
        } catch { return sessionError(error) }
    }

    router.get("sessions/:id/events") { _, context in
        do {
            let session = try await resolveSession(context)
            let id = session.id
            let running = await session.isRunningValue()
            let attachment = await app.hubAttachment(sinceEpoch: nil, sinceSeq: nil)
            let body = ResponseBody { writer in
                func write(_ event: BridgeEvent) async throws {
                    let data = (try? WireCoding.encoder.encode(event)) ?? Data()
                    var buffer = ByteBuffer()
                    buffer.writeString("data: ")
                    buffer.writeBytes(data)
                    buffer.writeString("\n\n")
                    try await writer.write(buffer)
                }
                try await write(.status(running ? "running" : "idle"))
                for frame in attachment.replay {
                    if case .session(let frameID, let event) = frame.event, frameID == id {
                        try await write(event)
                    }
                }
                try await withGracefulShutdownHandler {
                    for await frame in attachment.stream {
                        if case .session(let frameID, let event) = frame.event, frameID == id {
                            try await write(event)
                        } else if case .heartbeat = frame.event {
                            var buffer = ByteBuffer()
                            buffer.writeString(": hb\n\n")
                            try await writer.write(buffer)
                        }
                    }
                } onGracefulShutdown: {
                    Task { await app.detachHub(id: attachment.id) }
                }
                try await writer.finish(nil)
            }
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-cache"
            return Response(status: .ok, headers: headers, body: body)
        } catch { return sessionError(error) }
    }

    @Sendable func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt", "log", "md": "text/plain; charset=utf-8"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    @Sendable func saveAttachments(_ attachments: [SendAttachment], sessionID: String) -> [FileRef] {
        let dir = "\(config.attachmentsDir)/\(sessionID)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var refs: [FileRef] = []
        for attachment in attachments {
            guard let data = Data(base64Encoded: attachment.dataBase64) else { continue }
            let name = "\(Int(Date().timeIntervalSince1970))-\(attachment.filename ?? "file.bin")"
            let path = "\(dir)/\(name)"
            try? data.write(to: URL(fileURLWithPath: path))
            refs.append(
                FileRef(
                    path: path, mime: attachment.mime, filename: attachment.filename,
                    url: "/attachments/\(sessionID)/\(name)"))
        }
        return refs
    }

    @Sendable func sessionSnapshot(_ session: OmpSession) async -> Session {
        let messages = await session.snapshotMessages()
        let totals = await session.spendTotalsSnapshot()
        let lastTurn = await session.turnsSnapshot().last
        return Session(
            id: session.id, title: await session.titleText(),
            directory: await session.directoryPath(), ompSessionID: await session.currentOmpSessionID(),
            ompSessionFile: await session.sessionFile(), priorOmpSessionIDs: nil,
            model: await session.modelName(), effort: await session.effortLevel(),
            createdAt: await session.createdDate(), updatedAt: await session.updatedDate(),
            messages: messages, lastCostUSD: lastTurn?.costUSD,
            lastTokens: lastTurn?.tokens.total, customTitle: await session.customTitleValue(),
            autoTitled: await session.autoTitledValue(), interruption: nil, autoResume: nil)
    }

    @Sendable func resolveGitDirectory(_ request: Request, app: App) async -> String? {
        if let dir = request.uri.queryParameters.get("dir"), !dir.isEmpty {
            return NSString(string: dir).expandingTildeInPath
        }
        if let sessionID = request.uri.queryParameters.get("session") {
            if let session = await app.liveSession(id: sessionID) {
                return await session.directoryPath()
            }
            if let adopted = await app.adoptDiscovered(id: sessionID) {
                return await adopted.directoryPath()
            }
        }
        return nil
    }
}
