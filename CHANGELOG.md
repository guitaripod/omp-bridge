# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
Tailscode app reads this file from the project's head, so what it shows as new is exactly what is
listed here above the version a machine is running.

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
