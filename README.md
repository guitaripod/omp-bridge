# omp-bridge

A bridge that puts an [oh-my-pi](https://github.com/can1357/oh-my-pi) (omp) coding agent on a
tailnet, so remote clients can drive it like any other agent server. Sibling to
`claude-bridge`: same wire protocol, same self-update contract, different engine underneath.

omp speaks NDJSON over stdio (`omp --mode rpc`). This bridge owns those processes, one per
conversation, and exposes them as plain HTTP + Server-Sent Events.

## What it serves

| Area | Routes |
| --- | --- |
| Handshake | `GET /health`, `GET /status` (`agent: "omp"`, `proto: 2`) |
| Streaming | `GET /stream` (sequenced, replayable, epoch-cursored), `GET /sessions/:id/events` |
| Sessions | `GET/POST /sessions`, `GET/PATCH/DELETE /sessions/:id`, `/message`, `/abort`, `/clear`, `/fork` |
| Interruptions | `GET /sessions/:id/interruption`, `/resume`, `/interruption/dismiss` |
| Subagents | `GET /sessions/:id/agents[/:agentID]` |
| Money | `GET /sessions/:id/usage`, `GET /sessions/:id/spend`, `GET /analytics?days=N` |
| Search | `GET /search?q=&limit=` over every omp transcript on the machine |
| Commands | `GET /commands?session=` (live slash-command catalog from omp) |
| Files | `GET /files`, `/files/content`, `/files/raw`, `GET /attachments/:session/:name` |
| Git | `GET /git`, `/git/diff`, `/git/commit` (read-only) |
| Auth | `GET /auth`, `POST /auth/login`, `/auth/code`, `/auth/cancel` (omp provider login) |
| Update | `GET/POST /update`, `POST /update/restart`, `POST /update/auto` |

Everything is read-only or conversational; nothing stages, commits, pushes or deletes outside
its own state directory. 404 means *this server cannot say*.

## Mapping omp → wire

- One `omp --mode rpc` child process per conversation, cwd = the conversation directory.
- Protocol v2 chunked framing is negotiated at startup; oversized frames reassemble losslessly.
- `prompt` / `steer` map onto send-and-queue; a second prompt while a turn runs is queued
  FIFO and answered in order, never refused.
- `message_update` deltas stream straight through as `delta` frames; thinking blocks become
  reasoning parts; tool calls become tool parts with live output.
- omp's `ask` dialog (`extension_ui_request`) renders as an `AskUserQuestion` tool call; the
  client's next message resolves it as an `extension_ui_response`, and the call records the
  answer.
- `auto_compaction_*` events surface as compaction phases; `/compact [instructions]` sent as
  a message is intercepted and run through omp's own `compact` command with the instructions.
- Cost comes from omp itself (`usage.cost.total` per assistant message) — spend reports are
  sums of what the engine reported, always marked `estimated`.
- Sessions omp wrote itself (terminal runs) are discovered under `~/.omp/agent/sessions`,
  listed alongside managed ones, and adopted on first open without changing their identity.
  Deleting hides rather than destroys.

## Install

```sh
./install.sh
```

Builds from source, installs `~/.local/bin/omp-bridge`, stamps `~/.omp-bridge/build.json`
and writes a systemd --user unit (Linux) or launchd plist (macOS). Config lives in
`~/.config/omp-bridge.env`.

The bridge refuses to start without `OMP_PASSWORD`: omp runs tools with full permissions by
default, so an unauthenticated bridge is arbitrary code execution for anyone who can reach
the port. Clients authenticate with HTTP Basic auth; the password is what is checked, the
username is convention (`omp`) and any value is accepted.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `OMP_PORT` | `4099` | listen port |
| `OMP_BIND` | `127.0.0.1` | bind address (`0.0.0.0` for tailnet use) |
| `OMP_PASSWORD` | — (required) | Basic auth password |
| `OMP_WORKDIR` | `~/.omp-bridge/workdir` | default cwd for sessions |
| `OMP_BIN` | `/usr/local/bin/omp` | omp binary path |
| `OMP_STORE` | `~/.omp-bridge/sessions.json` | session store file |
| `OMP_STATE_DIR` | `~/.omp-bridge` | state, journals, update staging |
| `OMP_SRC` | auto-detected checkout | source the self-update rebuilds |
| `OMP_MODEL` | omp's default | default model for new sessions |
| `OMP_EFFORT` | `medium` | default effort/thinking level |

## Self-update

Same contract as claude-bridge: `version` (checkout) vs `running` (build stamp),
`restartRequired`, an explicit `remote` block, named obstacles, a quiet barrier **at exit**
so no running turn is ever torn down, `/update/restart` when a build landed without being
loaded, and `/update/auto` policy with exponential backoff held by the server, not clients.

## Development

```sh
swift build
swift test
scripts/smoke.sh   # end-to-end against a real omp binary
```

Requires Swift 6 and an installed `omp`. Tests cover the pure layers: NDJSON line framing,
JSON value bridging, transcript loading, discovery, hub replay semantics, store persistence,
spend aggregation.

## License

GPL-3.0
