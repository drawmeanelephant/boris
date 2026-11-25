# Watch JSON consumer recipe

**Status:** worked consumer recipe (non-normative). The normative stream contract lives in [docs/contracts/watch-mode.md](contracts/watch-mode.md#8---watch-json-ndjson-event-stream). If this recipe and the contract disagree, the contract wins.

`boris watch --watch-json` emits one JSON object per line (NDJSON) for every watch lifecycle and build phase. Use it to drive an automated edit and verify loop without scraping prose output or restarting the compiler.

## Redirect stderr, not stdout

Boris writes the NDJSON stream exclusively to **stderr** and leaves **stdout** empty. Piping stdout directly (`boris watch --watch-json | jq ...`) receives zero bytes and is the most common mistake on a first attempt.

Redirect file descriptor 2 to the pipe before sending file descriptor 1 to `/dev/null`:

```bash
boris watch --watch-json 2>&1 >/dev/null | ...
```

Keep that redirection order. Writing `>/dev/null 2>&1` instead sends both stdout and stderr to `/dev/null`.

## Minimal shell and jq consumer

This example uses `jq` as your own local tool. `jq` is not a Boris repository dependency, and this snippet is documentation prose rather than a shipped script.

```bash
boris watch --watch-json 2>&1 >/dev/null | {
  IFS= read -r first || { echo "stream ended before hello" >&2; exit 1; }
  schema="$(printf '%s\n' "$first" | jq -r 'select(.event == "hello") | .watch_events_schema')"
  if [ "$schema" != "1" ]; then
    echo "unsupported watch_events_schema: ${schema:-missing}" >&2
    exit 1
  fi

  while IFS= read -r line; do
    event="$(printf '%s\n' "$line" | jq -r '.event')"
    case "$event" in
      build-failed)
        printf '%s\n' "$line" | jq -c '.diagnostics[] | {code, sourcePath, line, remediation}'
        if [ "$(printf '%s\n' "$line" | jq -r '.recoverable')" = "false" ]; then
          echo "unrecoverable failure: watch session ending" >&2
          exit 1
        fi
        ;;
      build-succeeded)
        printf '%s\n' "$line" | jq -r '"ok (\(.phase)): pages_written=\(.pages_written) duration_ms=\(.duration_ms)"'
        ;;
      watch-error)
        printf '%s\n' "$line" | jq -r '"watch-error: \(.message) (recoverable=\(.recoverable))"' >&2
        ;;
      watch-stopped)
        break
        ;;
    esac
  done
}
```

The first record is always `hello`. Gate on `watch_events_schema == 1` before reading any build event, and refuse to continue on any other version or missing handshake.

To run the zero-write validation daemon with the same consumer, replace `boris watch --watch-json` with `boris validate --watch --watch-json`. Events keep the same schema with `"mode":"validate"` and `"pages_written":null`.

## Agent feedback loop

Run one long-lived watch process and react to its event stream:

1. Start `boris watch --watch-json` (or `boris validate --watch --watch-json`) with stderr redirected to your consumer, and verify that the first `hello` record carries `"watch_events_schema":1`.
2. Wait for `watcher-started`. The initial build completes before `watcher-started`, emitting either `build-succeeded` or `build-failed`.
3. When `build-failed` arrives with `"recoverable":true`, read each object in `diagnostics`: `code`, `sourcePath`, `line`, and `remediation` (`sourcePath`, `line`, `column`, and `id` can be `null` when absent).
4. Patch the source file named by `sourcePath`. Write to a sibling `.tmp` file and rename it over the target (`mv`), because the watcher ignores `.tmp` files and treats the rename as one clean change.
5. Wait for the next `build-succeeded` record to confirm recovery in the same session. Do not poll or scrape process exit codes during steady state, because the watcher stays alive across recoverable content and layout errors.
6. If `build-failed` arrives with `"recoverable":false`, stop waiting for further rebuilds. The compiler exits after emitting that record, with no trailing prose. Common causes are a missing content root, a hard I/O error, or a usage-class target declaration failure.

### Exit codes

`--watch-json` does not change Boris exit codes:

- `0`: success, or graceful shutdown on `SIGINT` or `SIGTERM` (after emitting `watch-stopped`).
- `1`: content validation failure (not used to end steady-state watch loops, which stay alive with `"recoverable":true`).
- `2`: usage or declaration error (such as `--watch-json` without watch mode, or a target declaration that fails startup).
- `3`: I/O or system failure (such as a missing content root or a `--serve` port conflict).

## Event vocabulary

Every line is one compact UTF-8 JSON object with a fixed key order and no prose interleaved on stderr.

| Event | When emitted |
| --- | --- |
| `hello` | First record; schema handshake |
| `build-started` | A build or rebuild cycle begins |
| `build-succeeded` | A build or rebuild completes without errors |
| `build-failed` | A build or rebuild fails (recoverable or unrecoverable) |
| `watcher-started` | The poll loop begins after the initial build (even if the initial build failed recoverably) |
| `serve-started` | `--serve` bound a loopback port (the only port discovery when `--port 0` is used) |
| `watch-error` | The watch loop hit a non-build error such as a poll failure |
| `watch-stopped` | Graceful shutdown on `SIGINT` or `SIGTERM` (`reason` is `"signal"`) |

Key fields across these events:

- `phase`: `"initial"` for the startup build or `"rebuild"` for a change-triggered cycle.
- `mode`: `"html"` for the publish watcher or `"validate"` for `boris validate --watch`.
- `targets`: the subset of targets rebuilt in this cycle, or `["default"]` in single-target and validate modes.
- `changed`: present on rebuild events only; the coalesced, sorted list of normalized changed paths.
- `pages_written`: pages written in this cycle, or `null` when unreported (always `null` in `"validate"` mode).
- `errors`: count of `error`-severity diagnostics on `build-failed`.
- `diagnostics`: array of report-shape objects with fields `severity`, `code`, `message`, `remediation`, `sourcePath`, `line`, `column`, and `id`.
- `recoverable`: `true` when the watcher stays running to await a fix, or `false` when the process exits after the event.
- `duration_ms`: elapsed build wall time in milliseconds.

## Sample events from contract §8

These records are copied byte for byte from [docs/contracts/watch-mode.md](contracts/watch-mode.md#8---watch-json-ndjson-event-stream).

`hello`:

```json
{"event":"hello","watch_events_schema":1,"compiler":"boris/2026.11.0"}
```

`build-started`:

```json
{"event":"build-started","phase":"initial","mode":"html","targets":["default"]}
```

`build-succeeded` (`html` mode):

```json
{"event":"build-succeeded","phase":"rebuild","mode":"html","targets":["default"],"changed":["index.md"],"pages_written":1,"duration_ms":45}
```

`build-succeeded` (`validate` mode):

```json
{"event":"build-succeeded","phase":"rebuild","mode":"validate","targets":["default"],"changed":["index.md"],"pages_written":null,"duration_ms":12}
```

`build-failed`:

```json
{"event":"build-failed","phase":"initial","mode":"html","targets":["default"],"errors":1,"diagnostics":[{"severity":"error","code":"EROUTEMISSING","message":"…","remediation":"…","sourcePath":"…","line":null,"column":null,"id":null}],"recoverable":true,"duration_ms":28}
```

`watcher-started`, `serve-started`, `watch-error`, and `watch-stopped`:

```json
{"event":"watcher-started","mode":"html","targets":["default"]}
{"event":"serve-started","url":"http://127.0.0.1:8090/","helper":"http://127.0.0.1:8090/__boris/","port":8090}
{"event":"watch-error","message":"poll error (BrokenPipe)","recoverable":true}
{"event":"watch-stopped","reason":"signal"}
```

## Existing consumers in this repository

For fuller reference integrations, inspect the two consumers already in the tree:

- [scripts/test-watch-json-contract.sh](../scripts/test-watch-json-contract.sh): bash 3.2 black-box contract guard run by `zig build test-watch-json-contract`.
- [editor/src/watch_daemon.zig](../editor/src/watch_daemon.zig): Zig supervisor that spools stderr to a file and drains events without blocking.
