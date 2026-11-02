import Foundation
import HTTPTypes
import Hummingbird

/// The schedules this machine keeps and asks, in the same shape claude-bridge serves them.
func registerScheduleRoutes(_ router: Router<BasicRequestContext>, app: App) {
    @Sendable func failure(_ error: Error) -> Response {
        jsonResponse(["error": String(describing: error)], status: .unprocessableContent)
    }

    @Sendable func missing() -> Response {
        jsonResponse(["error": ScheduleError.unknown.description], status: .notFound)
    }

    router.get("schedules") { _, _ in
        guard let scheduler = await app.scheduler else { return jsonResponse([Schedule]()) }
        return jsonResponse(await scheduler.list())
    }

    router.post("schedules") { request, _ in
        guard let scheduler = await app.scheduler else { return missing() }
        guard let draft = try? await decodeBody(ScheduleDraft.self, request) else {
            return jsonResponse(["error": "text and rule required"], status: .badRequest)
        }
        do {
            return jsonResponse(try await scheduler.create(draft), status: .created)
        } catch {
            return failure(error)
        }
    }

    router.get("schedules/:id") { _, context in
        guard let scheduler = await app.scheduler,
            let schedule = await scheduler.schedule(context.parameters.get("id") ?? "")
        else { return missing() }
        return jsonResponse(schedule)
    }

    router.patch("schedules/:id") { request, context in
        guard let scheduler = await app.scheduler else { return missing() }
        guard let patch = try? await decodeBody(SchedulePatch.self, request) else {
            return jsonResponse(["error": "nothing to change"], status: .badRequest)
        }
        do {
            return jsonResponse(try await scheduler.update(context.parameters.get("id") ?? "", patch))
        } catch ScheduleError.unknown {
            return missing()
        } catch {
            return failure(error)
        }
    }

    router.delete("schedules/:id") { _, context in
        guard let scheduler = await app.scheduler,
            await scheduler.delete(context.parameters.get("id") ?? "")
        else { return missing() }
        return jsonResponse(["ok": true])
    }

    router.post("schedules/:id/run") { _, context in
        guard let scheduler = await app.scheduler else { return missing() }
        do {
            return jsonResponse(try await scheduler.runNow(context.parameters.get("id") ?? ""))
        } catch ScheduleError.unknown {
            return missing()
        } catch {
            return failure(error)
        }
    }
}
