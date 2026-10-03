# codex-stdio2ws

Expose a shared `codex app-server` as a stdio JSON-RPC child process.

```
parent process                     codex-stdio2ws                  codex app-server
  stdin  (JSON-RPC lines) ──▶  stdin pump ──▶ WebSocket text frames ──▶  control socket
  stdout (JSON-RPC lines) ◀── socket pump ◀── WebSocket text frames ◀──  (Unix socket)
```

## Why

Paseo (and anything else that drives Codex over stdio) starts one private
`codex app-server` per session. Those processes cannot be shared: while
`codex app-server` is in its default `stdio://` mode it is single-client
(`single_client_mode` in Codex's app-server) and does not publish a control
socket, so other Codex clients cannot see or attach to those sessions.

Codex already ships the shared alternative: `codex app-server daemon start`
serves many clients over a control socket, and `codex agents` browses the
sessions on it. Two things get in the way of just using it:

1. The control socket is a **WebSocket** endpoint on a Unix socket
   (`GET /rpc`, `Host: localhost`), not a byte stream.
2. `codex app-server proxy` only relays bytes between stdio and that socket.
   It assumes the peer speaks WebSocket; a client that speaks
   newline-delimited JSON-RPC gets no response.

This program is the missing half: it performs the WebSocket upgrade itself and
bridges frames to lines. Existing stdio JSON-RPC clients need no changes.

## Build

Requires Zig 0.16.

```sh
zig build                  # zig-out/bin/codex-stdio2ws (ReleaseSafe)
zig build -Doptimize=ReleaseSmall
zig build test
zig build run -- --sock /path/to/app-server-control.sock
```

One of these runs per agent session, so the build mode is the whole story on
footprint. Measured idle RSS for the same binary connected to a daemon:

| `-Doptimize` | binary | idle RSS |
| ------------ | ------ | -------- |
| `Debug`      | 16.3MB | 5.2MB    |
| `ReleaseSafe` (default) | 4.0MB | 1.4MB |
| `ReleaseFast` | 4.0MB | 1.2MB |
| `ReleaseSmall` | 0.2MB | 0.9MB  |

ReleaseSafe is the default because it keeps Zig's checks: a parser bug panics
instead of reading past a frame. A 131KB response does not move RSS, so frame
payloads are not worth pooling.

## Usage

```sh
codex-stdio2ws [--sock <path>]
```

`--sock` defaults to `$CODEX_HOME/app-server-control/app-server-control.sock`,
falling back to `$HOME/.codex/app-server-control/app-server-control.sock`.
Start the daemon first if it is not running:

```sh
codex app-server daemon start
printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"probe","title":"probe","version":"1.0.0"}}}' \
  | codex-stdio2ws
```

Set `CODEX_STDIO2WS_DEBUG=1` to log frame traffic to stderr. stdout stays a
clean JSON-RPC channel; every diagnostic goes to stderr.

## Behaviour worth knowing

### Using it as a provider command (no host changes)

Anything that lets you replace the `codex` command can point at this binary
instead, without host code changes:

```json
{
  "command": {
    "mode": "replace",
    "argv": ["codex-stdio2ws", "--sock", "/home/me/.codex/app-server-control/app-server-control.sock"]
  }
}
```

Omit `--sock` to derive it from the child's `CODEX_HOME`. Hosts that append
their own arguments are fine: `app-server`, `--stdio`, `--enable <feature>` and
`--disable <feature>` are accepted and ignored, so
`codex-stdio2ws --sock <path> app-server --enable goals` works. Feature flags
are fixed when the shared daemon starts, so a per-session `--enable` cannot
take effect here — check that the daemon already has the feature, or the host
will advertise a capability the daemon will reject.

`--version` reports the codex version behind the daemon (read from the
daemon's `initialize` response) so version-gated features in the host keep
working. It prints `codex-cli 0.0.0 (codex-stdio2ws; daemon unreachable)` when the daemon is
down, which reads as "too old" rather than crashing the probe.

- One line in, one WebSocket text frame out, and the reverse. Blank lines are
  skipped. Frames larger than 64 MiB are refused instead of allocated.
- Client frames are masked; server frames are expected unmasked. Ping is
  answered with Pong, Close is answered and then the process exits 0.
- `Sec-WebSocket-Extensions` is deliberately not sent. The control socket does
  not support permessage-deflate, and advertising it makes the server drop the
  connection — a plain WebSocket client that negotiates extensions by default
  will fail here.
- stdin EOF sends a Close frame and exits immediately; that is what a parent
  terminating the child expects.
- The daemon is not owned by this process. There is no refcounting, no idle
  shutdown and no restart logic: `codex app-server daemon` already starts
  idempotently, unloads threads that have no subscribers, and owns its own
  lifecycle. Losing the connection ends this process, and the parent decides
  what to do about it.

## Limits

- No permessage-deflate or subprotocol negotiation. Text and binary messages
  are reassembled from continuation frames; the 64 MiB limit applies to each
  frame, not the total reassembled message.
- `--profile` is not a thing here and cannot be: profile selection is a
  daemon-start input in Codex (`codex app-server` rejects `--profile`), not a
  per-connection property. Per-thread `config` overrides on `thread/start`,
  `thread/resume` and `thread/fork` are the supported substitute.
