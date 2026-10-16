# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
Tailscode app reads this file from the project's head, so what it shows as new is exactly what is
listed here above the version a machine is running.

## Unreleased

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
