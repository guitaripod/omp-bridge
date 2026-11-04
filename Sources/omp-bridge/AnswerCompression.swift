import Hummingbird
import HummingbirdCompression

/// Gzips the answers that are whole documents — a transcript, the session list, analytics — for a
/// client that says it can read gzip, which URLSession on every platform the apps run on says on
/// its own and undoes on its own.
///
/// A transcript is JSON that repeats the same keys on every message, so it shrinks about four
/// times: a long conversation that was six megabytes on the wire to a phone on a cellular tailnet
/// becomes one and a half. Nothing else changes for the client, which never sees the encoding.
///
/// Event streams are left alone. Their frames are small, arrive one at a time and must reach the
/// client the moment they are written, which is exactly what a compressor's buffering is for
/// holding back. So is anything already compressed (a picture over `/files/raw`) and anything with
/// no length, which is a stream by another name.
struct AnswerCompression<Context: RequestContext>: RouterMiddleware {
    private let compressor = ResponseCompressionMiddleware<Context>(
        minimumResponseSizeToCompress: AnswerCompression.minimumSize)

    static var minimumSize: Int { 1024 }

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        guard Self.isDocument(response) else { return response }
        return try await compressor.handle(request, context: context) { _, _ in response }
    }

    /// Whether an answer is a finished document worth compressing: a known length, no encoding of
    /// its own, and a textual type.
    static func isDocument(_ response: Response) -> Bool {
        guard response.body.contentLength != nil, response.headers[.contentEncoding] == nil,
            let type = response.headers[.contentType]?.lowercased()
        else { return false }
        if type.hasPrefix("text/event-stream") { return false }
        return type.hasPrefix("application/json") || type.hasPrefix("text/")
    }
}
