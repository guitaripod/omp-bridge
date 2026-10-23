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
| Sessions | `GET/POST /sessions`, `GET/PATCH/DELETE /sessions/:id`, `/revision`, `/wait`, `/message`, `/abort`, `/clear`, `/fork` |
| Interruptions | `GET /sessions/:id/interruption`, `/resume`, `/interruption/dismiss`, `/auto-resume` |
| Subagents | `GET /sessions/:id/agents[/:agentID]` |
| Money | `GET /sessions/:id/usage`, `GET /sessions/:id/spend`, `GET /analytics?days=N` |
| Models | `GET /models` (omp's own catalog: provider, thinking levels, context window; cached 5 min) |
| Search | `GET /search?q=&limit=` over every omp transcript on the machine |
| Commands | `GET /commands?session=` (live slash-command catalog from omp), `GET /commands[?directory=]` (the machine's catalog with no chat open — a scratch omp asked in that directory, cached 5 min) |
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
curl -fsSL https://raw.githubusercontent.com/guitaripod/omp-bridge/master/install.sh | bash
```

Requirements: Linux (x86_64 or aarch64, glibc 2.35 or newer, which is every mainstream
distribution since 2022) or macOS 14+ on Apple silicon, `curl`, and
[oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`). **No Swift toolchain and no `git`**: the
installer downloads a prebuilt program, checks its SHA-256 (integrity; the download itself is
HTTPS from GitHub), installs `~/.local/bin/omp-bridge`, stamps `~/.omp-bridge/build.json` and
writes a systemd --user unit (Linux) or launchd plist (macOS). Config lives in
`~/.config/omp-bridge.env`.

Before it installs anything it looks at the machine and says what it found, in plain words:

- **Tailscale**: installed, signed in and connected? It is what lets a phone reach the machine
  from anywhere. If it is missing or signed out the installer says exactly what to do and carries
  on, because the bridge still works on that computer and on the home network.
- **omp**: installed, and signed in to a model provider?

It ends with a short list of what is still left to do, only the things that are actually left
(Tailscale on this computer and on the phone, signing omp in), and then the pairing link and code
(see [Pairing a phone](#pairing-a-phone)); a program too old to know `pair` gets the address and
password for a client instead.

If there is no prebuilt program for the machine, the download fails, or the checksum does not
match, the installer says why in one sentence and builds from source instead (clone into
`~/.omp-bridge/src`, `swift build`; 5 to 15 minutes), and if Swift is missing then, says where to
get it: <https://www.swift.org/install/>. `--from-source` asks for that build directly, and
`--no-service` installs everything except the service. A machine that already has a source
checkout keeps building from it. Re-running the installer updates in place and keeps the config.

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
| `OMP_RELEASE_BASE` | the project's `releases/latest/download` | installer only: where `latest.txt`, the archives and `CHANGELOG-<version>.md` are served from; a prebuilt install records the one it used in `install.json` and the bridge reads it from there |
| `OMP_TAILSCALE` | found on the PATH and in the usual places | `tailscale` program `pair` and the installer ask for the machine's name |
| `OMP_MODEL` | omp's default | default model for new sessions |
| `OMP_EFFORT` | `medium` | default effort/thinking level |
| `OMP_TITLE_MODEL` | the session's model | model that writes a conversation's title |
| `OMP_WAIT_MAX` | `10800` (3h) | seconds `GET /sessions/:id/wait` holds before answering `running` |

## Waiting on a turn

`GET /sessions/:id/wait` is a long poll with no cursor: it answers once, when there is
something worth telling a client that stopped watching — never a stream of updates. A client
that already knows what it is waiting for (a background URLSession, a client that was closed)
hands over the session id and gets back exactly one JSON object, whenever it is ready.

The response is `200`, chunked, with no content-length: a single `\n` leaves with the headers
so nothing reads the connection as dead on the first byte, then another `\n` every 10 seconds
while it holds. The body itself is a JSON object, and leading whitespace before a JSON value is
valid (RFC 8259), so a client decodes the whole response in one pass rather than looking for a
delimiter.

It resolves the moment the session has nothing left to wait for: the turn ended (`state:
"ended"`, with the ending it actually had — `finished`, `answerless`, `failed`, `cancelled` or
`interrupted`, read from what omp itself recorded, never guessed), or the turn is waiting on the
person (`state: "needsYou"`, `ending: "question"` — omp has no separate approval step). If
nothing was ever open when the request arrived, it answers at once with `waited: false` and the
last turn's ending, if one is known. A session a terminal is running rather than the bridge
(`externallyLive`) is watched on the same short poll the bridge already uses to keep that flag
current, so waiting on one blocks exactly as long as `/revision` would say it should.

A hold that outlasts `OMP_WAIT_MAX` answers `state: "running"` — still going, ask again — rather
than holding the connection forever. A client that disconnects ends its own hold; the bridge
notices on the next write and drops the loop. Two clients waiting on the same session at once is
ordinary, and each gets its own answer the moment the session settles.

`GET /status` carries `turnWait: 1`, the protocol version of this route, so a client can tell
"too old to have this" from "session not found" without probing blind.

## Shared queue

A message queued behind a running turn lives on the bridge, not on the device that queued it, so
every client of the conversation shows the same queue and can edit or cancel it. Same contract as
claude-bridge's. The bridge drains it: when a turn closes and no compaction is running, the head
starts, unless the queue is paused.

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/sessions/:id/queue` | none | `{"queue": [Item], "paused": bool}` |
| POST | `/sessions/:id/queue` | `{id, text, kind?: "prompt"\|"command", model?, effort?, attachments?}` | `{"started": bool, "queue": [Item], "paused": bool}`. `id` is the client's own UUID and makes the call idempotent. Nothing running: the item starts at once and never appears in the queue. Otherwise it is appended. Either way the queue stops being paused |
| PATCH | `/sessions/:id/queue/:qid` | `{text?, model?, effort?}` | the snapshot; `409 {"error": "already_started"}` when the item started or is gone |
| DELETE | `/sessions/:id/queue/:qid` | none | the snapshot (also when the id is already gone); `409 already_started` when it has started |
| POST | `/sessions/:id/queue/resume` | none | the snapshot; clears `paused` and starts the head when idle |

An item is `{id, text, kind, model?, effort?, attachments, createdAt}`; `attachments` is metadata
only (`{mime, filename, size}`), the bytes arrive once with the enqueue as `dataBase64` and are
kept under the state directory's `attachments/`. A queued item is not in the transcript: its user
message is written when it starts. `POST /sessions/:id/abort` ends the running turn and sets
`paused` (the items stay); a new message, an enqueue or `resume` clears it. The queue is kept in
`queues/<session>.json` in the state directory and comes back `paused: true` after a restart. The
legacy `POST /sessions/:id/message` stays: sent while a turn runs it becomes an item with a
bridge-made id. Every change is an SSE frame `{"type": "queue", "queue": [Item], "paused": bool}`
with the whole snapshot, also on `/stream`; the hello of `/sessions/:id/events` includes it when
the queue is non-empty or paused, and `GET /sessions/:id` carries `queue` and `queuePaused`.
`GET /status` carries `queue: 1`.

## Session marks

What a person decides about a conversation lives here, beside the transcripts, so every client
reads one answer. Same contract as claude-bridge's: `PATCH /sessions/:id` takes
`{title?, saved?, pinned?, archived?, read?: "seen"|"unread", at?}`, where `at` is when the person
decided and each mark keeps the later decision rather than the later arrival. Marks are accepted
for any id, including a transcript the bridge has only discovered; a title still needs a session.
Every summary — `GET /sessions` rows and `list.upsert` frames — carries `saved`, `pinned` and
`archived` (false included), `pinnedAt` while pinned, and `readAt` once any client has marked the
chat, in this bridge's clock so it compares with `updatedAt` (unread when `updatedAt` is more than
a second past it). They persist in `marks.json` beside the store, are dropped with the
conversation, and are forgotten for ids nothing has listed for thirty days. `GET /status` carries
`marks: 1`.

## Self-update

Same contract as claude-bridge: `version` (checkout) vs `running` (build stamp),
`restartRequired`, an explicit `remote` block, named obstacles, a quiet barrier **at exit**
so no running turn is ever torn down, `/update/restart` when a build landed without being
loaded, and `/update/auto` policy with exponential backoff held by the server, not clients.

**A prebuilt install updates itself too, without a checkout.** The installer leaves two things in
the state directory: `install.json` (`{"mode":"release","repo":…,"base":…}`, where releases are
published) and `install.sh` with its `install.sh.sha256`, the installer that arrived inside the
release archive and was verified by the archive's own checksum. The bridge then answers `GET
/update` in exactly the shape a checkout gives:

- *What is newer* is the release's `latest.txt`, read with one conditional request (`ETag`) at
  most every five minutes however often a client asks (Check now has a ten-second floor), and
  compared as numbers (`0.10.0` is newer than `0.9.0`). A pointer that is not a plain dotted
  version is reported in `remote.error` and never acted on; with no network the answer keeps what
  was last heard, `remote.ok` is `false`, and the error says it could not reach the project.
- *What is new* is the `CHANGELOG-<version>.md` asset of that release (the changelog as of it,
  fetched once per version), cut down to the releases newer than the one running: `release.version`
  is the offered version, `release.commitsPastTag` is `0`, `release.notes` carries the sections.
  A release that publishes no such asset costs only the notes.
- *Doing it* is `POST /update` running the kept installer as `install.sh --update --managed`
  after checking it against its checksum again; it downloads the archive, refuses it unless its
  SHA-256 matches and the program starts, and only then puts it in place. A checksum that does not
  match leaves the running program, the installer and the record as they were, fails the job in
  its `download` step with the sentence the installer wrote, and counts against the unattended
  backoff like a build that does not compile. The quiet barrier, the phases, the job and the
  unattended policy are the checkout path's, untouched.

Only `behind` (the number of commits) is absent: a release machine does not count in commits. A
checkout wins over a record, and a machine installed by an older installer, without `install.json`
or a kept installer, says what is missing (`obstacle.kind` `noInstaller`) and is brought across by
running the install command once. `install.sh --update` on such a machine does the same download
and install by hand, finding the release where `install.json` says. The checkout the bridge takes
for its own is found by walking up from the program to a directory with both `.git` and
`Package.swift`, so a home directory that happens to be a git repository is not mistaken for one.

## Pairing a phone

```sh
omp-bridge pair                 # the link, a QR code, how to show it again
omp-bridge pair --link-only     # just the link, for scripts
omp-bridge pair --json          # everything, machine-readable
```

prints the `tailscode://connect?v=1&host=…&port=…&agent=omp&name=…&key=…` link the Tailscode apps
open, and a QR code of it for the phone's camera (colours on a terminal, plain blocks in a pipe;
`--color always|never` decides). It reads the port and password from the environment, then from
`~/.config/omp-bridge.env`, so it works from a shell as well as from the installer.

- **Host**: this computer's MagicDNS name from `tailscale status --json`, else its tailnet IPv4,
  else IPv6. On a machine that is not on a tailnet (no Tailscale, signed out, turned off, not
  answering) it is the hostname with a plain note saying so, and no code, because a phone away
  from this network cannot use it; `--any-host` prints the code anyway, and `--link-only` refuses
  (exit 3) without it.
- **`key`** (the password) is always in the link while a password is set. omp-bridge's only door is
  the Basic-auth password (`BasicAuthMiddleware` in `main.swift`), it never asks Tailscale who is
  calling, and it refuses to start without a password, so there is no tailnet trust for the link
  to lean on. The key is shown only on the terminal that asked, `PairingLink` redacts it
  everywhere it is printed by that type, and `--json` carries `redacted` beside `link`.
- **name** is the hostname, without its domain.

The installer ends by running exactly this.

## Development

```sh
swift build
swift test
scripts/smoke.sh          # end-to-end against a real omp binary
scripts/test-install.sh   # the installer, offline, against a fake release
scripts/package-release.sh   # the release archive (program, license, installer), its checksum and CHANGELOG-<version>.md
```

`scripts/fake-release-server.py` is the release server the Swift tests use (ETag, request log);
they install from it into temporary homes and run whole updates against it.

The bridge depends on CodingAgentKit's `PairingKit` product for the link format and the QR
encoder. `Package.swift` takes a sibling working copy (`../CodingAgentKit`) when there is one and
the published tag (`Kit.version`) otherwise; `OMP_BRIDGE_KIT_REMOTE=1` forces the tag, which a
release build should set.

Requires Swift 6 and an installed `omp`. Tests cover the pure layers: NDJSON line framing,
JSON value bridging, transcript loading, discovery, hub replay semantics, store persistence,
spend aggregation.

## License

GPL-3.0
