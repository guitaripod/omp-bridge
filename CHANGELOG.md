# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
Tailscode app reads this file from the project's head, so what it shows as new is exactly what is
listed here above the version a machine is running.

## 0.13.0 — 2026-11-10

- Chapters, as claude-bridge keeps them. Every third message the engine looks at whether the chat still wears the right name; where the topic moved, the chat is renamed and a chapter opens at the message where it turned, and the chapter it closed gets one sentence saying what it came to. The app lists them in the chapters panel and marks each one in the conversation. A name you gave the chat stays; the chapters still follow the topic under it. A chat older than this with six or more messages is split into its chapters once, the first time it is opened. The looks run on the chat's own model (or `OMP_TITLE_MODEL`); a model that thinks out loud first is read past its thinking, a split that opens a chapter at nearly every message is not used, and one finer than a chapter per three messages is folded to that.
- A turn that failed stays in the chat. An answer oh-my-pi ended with an error — a provider out of credits answering HTTP 402, say — keeps the provider's words, live and when the chat is opened later, instead of leaving a prompt nobody answered.
- `/clear` names the chat afresh from what is said next.

## 0.12.3 — 2026-11-10

- A new chat survives a restart before its first message. oh-my-pi writes a conversation to disk only once the first message reaches it, and the bridge forgot any chat without one when it restarted, so a chat opened just before an update, a reboot or a crash answered every message after it with "not found". Such a chat comes back empty now, and a chat is saved the moment it is made.

## 0.12.2 — 2026-11-09

- The Mac bridge no longer crashes when a phone sends it a message over a cellular network. 0.11.0 to 0.12.1 for macOS were built by Xcode 26, whose Swift compiler mishandles a request whose body arrives a moment after its headers: the bridge died on every such send, the phone said the network connection was lost, and the bridge restarted. It is built by Xcode 27 now, and every release is started and sent a late body before it is published. Linux releases were never affected.

## 0.12.1 — 2026-11-09

- The sign-in check that runs every minute starts oh-my-pi without its skills, so it no longer wakes the small model on your graphics card to compress skill descriptions it exits before reading.

## 0.12.0 — 2026-11-06

- `GET /sessions/:id/wait?until=settled` holds the phone's background wait until the conversation's work is over: no turn, no queued prompt waiting to start one, no sub-agent still at work, and ten seconds of quiet, so the phone says one piece of work is done once rather than once per turn. The answer says `settled: true` and its duration covers the whole stretch; `/status` says `turnWait: 2`.

## 0.11.0 — 2026-11-04

- Sub-agents show up. Every field of oh-my-pi's sub-agent frames was read from the wrong level, so no omp chat ever listed an agent; each now carries its kind, the call that started it, its tool count and current tool, and starts, ends and progress reach the app on the stream as they happen.
- A turn closes the moment oh-my-pi says it ended — completed, stopped or failed with the provider's words — instead of after twenty quiet seconds, and a slash command the engine answers itself closes at once with what it printed as the reply.
- A turn waiting on its provider between attempts says so: a `retry` frame with the attempt, the provider's reason and when it tries next, as claude-bridge sends it.
- A long tool output keeps its start and its end rather than only its first 10 KB, and a running command's output goes out at most four times a second.
- "Other (type your own)" in a question works instead of freezing the turn, and an ask the engine withdraws closes.
- Error notices from the engine reach the chat, and a model or thinking level the engine switches to by itself reaches the model chip.
- Answers that are whole documents are gzipped, and the session list and every session read are tagged so an unchanged one is answered 304.
- Wire parity with claude-bridge: Stop with nothing to stop answers 409, `/status` carries `access` and `detail`, and the session read carries `scheduleID`, the cut-off turn and the provider wait.
- A prompt whose run yielded to background work keeps its turn open until the engine says the session settled, and an answer a slash command printed before starting a run of its own is kept.
- Reads each engine's output on a thread of its own, so many omp chats at once can no longer starve the bridge.
- Asks the engine only for what it reads: sub-agents at progress level and message updates as deltas.

## 0.10.0 — 2026-11-03

- Keeps schedules on the machine, in the shape claude-bridge serves them, so a question asked every morning is asked whether or not any app is open: `GET/POST /schedules`, `PATCH/DELETE /schedules/:id`, `POST /schedules/:id/run`. Runs go into one conversation that remembers by default; a run with nothing new is one plain line and leaves the chat read, while a failure always speaks; a machine that was off asks once for what it owed and records how many times it missed. `/status` reports `schedules`, `/stream` carries a `machine` frame when they change, and a conversation a schedule made is `scheduled: true` in a listing.

## 0.9.1 — 2026-10-25

- The 0.9.0 release has no downloads, because its macOS build failed on the older Swift compiler the release machine uses; 0.9.1 has them for Linux and macOS, so a bridge installed from a release can update again. Nothing else changes.

## 0.9.0 — 2026-10-23

- A message queued behind a running turn now lives on the bridge, so every device on the conversation shows the same queue and can edit or cancel it, instead of the phone that queued it being the only one to know. `GET /sessions/:id/queue` reads it; `POST /sessions/:id/queue` adds an item under the client's own id (idempotent, and started at once when nothing is running), `PATCH` and `DELETE /sessions/:id/queue/:qid` change or cancel one that has not started (`409 already_started` once it has), and `POST /sessions/:id/queue/resume` lets a paused queue run. Every change is a `queue` event carrying the whole queue, `GET /sessions/:id` carries `queue` and `queuePaused`, and `/status` reports `"queue": 1`. Same contract as claude-bridge's.
- A queued message is not in the conversation until it starts: its user message is written when its turn begins. The bridge starts the next one only when neither a turn nor a compaction is running.
- Stop pauses the queue instead of throwing it away, and a new message, an enqueue or Resume lets it run again. A queue survives a restart, attachments included (it is kept in `queues/` in the state directory), and comes back paused so nothing runs unattended after a crash.
- An older app sending while a turn runs still works: its message joins the queue like any other, so a newer app sees it.

- Installing no longer needs Swift or git. The installer downloads a prebuilt program for the machine (Linux x86_64 and aarch64, macOS on Apple silicon), checks its SHA-256 and starts it, in seconds instead of a long build. It builds from source only when there is no program for the machine, the download fails or does not check out, or `--from-source` asks, and then says why in one sentence and where to get Swift if it is missing. The source build no longer needs `OMP_REPO` to know where the project lives.
- The installer looks at the machine first and says in plain words whether Tailscale is installed and signed in and whether omp is installed and signed in, carries on either way, and ends with what is actually left to do and the address and password for a client. `--no-service` installs everything except the service. The bridge answers `--version`, and refuses an argument it does not know rather than starting a second server.

- A machine installed from the prebuilt release now updates itself from Tailscode like any other. It looks for a newer release by reading the release's version pointer (one conditional request at most every five minutes, tolerant of being offline), tells the app what is new from that release's changelog, and runs the installer it kept from its own archive, which refuses any download whose checksum does not match and leaves the running program alone when one does not. Everything the app reads keeps its shape; the quiet wait before a restart, the job steps and the unattended policy are the ones a source install has.
- `omp-bridge pair` prints the link and the QR code Tailscode scans to find this machine, and the installer ends with it. It names the machine by its Tailscale name (or address) and says plainly when it is not on a tailnet; the password is always in the link, because this bridge lets nobody in without it. `--link-only` and `--json` are for scripts.
- Release archives now carry the installer they were made with, and each release publishes `CHANGELOG-<version>.md` beside them.
- A home directory that is itself a git repository is no longer mistaken for the bridge's checkout, which would have hidden a prebuilt install's own way of updating.
- The installer's time limit on the programs it asks things of no longer leaves a sleeping timer behind for the rest of the limit.

## 0.8.0 — 2026-10-10

- The bridge now keeps what a person decides about each conversation — saved, pinned, archived and when it was last read — so every device reads the same answer from the machine that holds the chat. `PATCH /sessions/:id` takes `saved`, `pinned`, `archived` and `read` (`seen` or `unread`), each stamped with when the person decided so a phone that was offline cannot overrule a later choice, and every conversation in a listing or a live `list.upsert` carries them. `/status` reports `marks` so a client can tell a bridge that holds them from one that does not. Same contract as claude-bridge's.

## 0.7.0 — 2026-09-25

- `GET /sessions/:id/wait` holds a connection open until a turn ends or asks the person something, instead of a client having to poll — the same shape as claude-bridge's, so a phone that has closed can wake on either engine. `GET /status` reports `turnWait: 1` so a client can tell an older bridge apart from a session it cannot find.
- A turn that used no tools no longer tells the phone it used one: `/wait`'s tool count is the real count, zero included, and only the billing ledger keeps its own "at least one call" accounting.

## 0.6.3 — 2026-09-25

- The bridge no longer restarts itself every two minutes when its checkout carries a commit that was never built. A restart is offered only when a newer build is waiting on disk, so pressing Restart loads it and the offer goes away, instead of coming back on the same build still asking to be restarted.
- A client that drops its live connection no longer leaves the bridge holding and feeding a dead subscriber for the rest of its life.

## 0.6.2 — 2026-09-24

- Pressing Restart on a bridge with a newer build waiting no longer gets refused, and the bridge no longer reports a build it hasn't started as the one running.
- A restart takes seconds rather than a minute and a half: helper processes that ignore the stop signal are ended after 15 seconds instead of 90. Existing installs pick this up the next time the installer writes the service.

## 0.6.1 — 2026-09-23

- Restarting or updating the bridge no longer moves every chat to the top of the list: a chat is dated by the last thing said in it, and chats an earlier restart re-dated go back to where they belong.
- A chat leaves Live Now as soon as its answer ends, instead of three minutes later, and a restart no longer shows every chat it closed as live.

## 0.6.0 — 2026-09-23

- Updates are followed step by step — download, build, waiting for idle, restart — and every update reports how it ended and which version it landed on.
- The app shows what is new in an update, read from this changelog.

## 0.5.6 — 2026-09-17

- Chats are named by a model once there is something to name, and a name once written stays.
- A title the chat's own model cannot write is asked of omp's default model instead.

## 0.5.5 — 2026-09-16

- A session found on disk is named after its first prompt and shows its model right away.
- Models are always shown as provider/id, and a turn that died is closed on the bridge's own clock.

## 0.5.4 — 2026-09-05

- The slash-command list answers without a chat open, so quick asks see the machine's commands.

## 0.5.3 — 2026-09-05

- Subscription models that report no cost are priced at their provider's published rates instead of showing $0.
