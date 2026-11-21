import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import TerminalHost
import TerminalWire

/// The shells this machine holds for its clients.
///
/// A terminal here is a login shell on a pseudo-terminal the bridge owns, started in the folder a
/// conversation works in. It belongs to the bridge, not to the client that opened it: the app can
/// close, the phone can sleep and the connection can drop, and the shell, its folder and whatever
/// it was running are there when a client comes back. It is the same reach the bridge already
/// gives, a person who may run an agent on this machine may type on it, behind the same door.
///
/// Output is one long answer of framed bytes (`TerminalFrame`), read from a position so a client
/// that comes back misses nothing and repaints nothing. Keys go the other way as plain requests,
/// each answered once its bytes are in the shell's queue.
func registerTerminalRoutes(
    _ router: Router<BasicRequestContext>, hall: TerminalHall,
    directory: @escaping @Sendable (String) async -> String?
) {
    @Sendable func seat(_ context: BasicRequestContext) -> TerminalSeat? {
        context.parameters.get("id").flatMap { hall.seat($0) }
    }

    @Sendable func missing() -> Response {
        jsonResponse(["error": "That terminal is no longer open on this machine."], status: .notFound)
    }

    router.get("terminals") { _, _ in jsonResponse(hall.list()) }

    router.post("terminals") { request, _ in
        var asked =
            (try? await decodeBody(TerminalOpenRequest.self, request)) ?? TerminalOpenRequest()
        if (asked.directory ?? "").isEmpty, let session = asked.session {
            asked.directory = await directory(session)
        }
        do {
            return jsonResponse(try hall.open(asked).info())
        } catch let error as TerminalHostError {
            let status: HTTPResponse.Status
            if case .tooMany = error { status = .conflict } else { status = .serviceUnavailable }
            return jsonResponse(["error": error.description], status: status)
        }
    }

    router.get("terminals/:id") { _, context in
        guard let seat = seat(context) else { return missing() }
        return jsonResponse(seat.info())
    }

    router.get("terminals/:id/output") { request, context in
        guard let seat = seat(context) else { return missing() }
        let from = request.uri.queryParameters.get("from").flatMap { UInt64(String($0)) }
        var headers = HTTPFields()
        headers[.contentType] = "application/octet-stream"
        headers[.cacheControl] = "no-store"
        headers[.xContentTypeOptions] = "nosniff"
        let body = ResponseBody { writer in
            for await piece in seat.feed(from: from) {
                var buffer = ByteBufferAllocator().buffer(capacity: piece.count)
                buffer.writeBytes(piece)
                try await writer.write(buffer)
            }
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    router.post("terminals/:id/input") { request, context in
        guard let seat = seat(context) else { return missing() }
        let buffer = try await request.body.collect(upTo: 1 << 20)
        seat.send(Data(buffer.readableBytesView))
        return Response(status: .noContent)
    }

    router.post("terminals/:id/resize") { request, context in
        guard let seat = seat(context) else { return missing() }
        guard let size = try? await decodeBody(TerminalResizeRequest.self, request) else {
            return jsonResponse(["error": "cols and rows required"], status: .badRequest)
        }
        seat.resize(cols: size.cols, rows: size.rows)
        return jsonResponse(seat.info())
    }

    router.delete("terminals/:id") { _, context in
        guard let id = context.parameters.get("id"), hall.close(id) else { return missing() }
        return jsonResponse(["ok": true])
    }
}
