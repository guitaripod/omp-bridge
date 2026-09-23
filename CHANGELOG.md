# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
Tailscode app reads this file from the project's head, so what it shows as new is exactly what is
listed here above the version a machine is running.

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
