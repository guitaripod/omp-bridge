# omp-bridge — agent instructions

A Swift 6 / Hummingbird daemon that drives oh-my-pi (`omp --mode rpc`) and speaks the exact
wire protocol `claude-bridge` serves, so the same clients work against both. Read README.md
for the route table and mapping rules before touching anything.

## Non-negotiables

- **The wire contract is the contract.** JSON field names in this repo mirror
  `claude-bridge`'s DTOs exactly (`Sources/claude-bridge/Models.swift` et al). A field rename
  here silently breaks every client; do not rename Codable keys.
- **No comments, no MARK, no file headers.** Same rule as the sibling repos.
- **Swift 6 strict concurrency.** Actors own their state; cross-actor calls are `await`.
  Local functions captured into route closures need `@Sendable`.
- **404 means "this server cannot say".** Missing capability (plan gauges, push) answers 404
  or 501 with an error sentence, never a fake empty success.

## Layout

- `Wire.swift` — every client-visible DTO + `BridgeEvent` vocabulary. Changes here are
  protocol changes.
- `OmpProcess.swift` — child process, NDJSON framing, v2 chunk reassembly, request
  correlation. The only place that talks to omp's stdio.
- `OmpSession.swift` — one conversation: event mapping (omp frames → BridgeEvents), queueing,
  ask-dialog handling, spend accumulation, title derivation.
- `App.swift` — session registry, discovery merge, observer sweep, interruption recovery,
  update plumbing.
- `Hub.swift` — epoch/seq ring for `/stream`; replay or `reset`, never silence.
- `SessionStore.swift` / `TurnJournal.swift` — persistence; journal-before-spawn so a killed
  turn is recovered as an interruption, never lost.
- `Update.swift` + `install.sh` + `Quiescence.swift` — self-update machinery, quiet barrier at
  exit.
- `TranscriptLoader.swift` / `Discovery.swift` / `TranscriptSearch.swift` — omp transcript
  format (`~/.omp/agent/sessions/<escaped-cwd>/*.jsonl`) is the source of truth for anything
  the bridge did not run itself.

## Testing

`swift test` covers the pure layers. When changing OmpProcess/OmpSession mapping logic, add a
fixture-based test (transcripts are tiny JSONL fixtures). For end-to-end verification against
a real omp: build release, run with `OMP_PASSWORD=test OMP_BIN=$(which omp)`, then create a
session, send a message with a local model, and check `/sessions/:id` shows user + assistant
messages with cost.

## Versioning / releases

Tags drive `git describe`; install.sh stamps `build.json` so `running` vs `version`
divergence reads as `restartRequired`. Commit finished work on `master`.
