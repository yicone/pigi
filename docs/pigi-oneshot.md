# pigi-oneshot: hardened one-shot read commands (ACM-980)

`tools/pigi-mcp/pigi_oneshot.py` is a fixed-shape, single-invocation reader for the
Billing local-execution channel. Each run performs exactly one of four read
subcommands against the already-running App's `agent.sock`, through a child
`pigi_mcp.py` scoped to one pinned account, then exits. There is no daemon, no
shell, no free-form input path, and no mail-write or mutation path anywhere in
the chain (no send, mark-read, draft or delete). The wrapper itself writes no
files; the child adapter it spawns writes its own content-free `tool_calls`
audit rows to the adapter audit DB, and the App writes `agent_actions` — both
pre-existing ledgers, see Audit below.

Everything the caller can reach is fixed by code and config: the target mailbox,
the allowed senders, the search query (`Cursor`), the subcommands, and every
bound. No environment variable or option selects an account, socket, or config
path.

## Invocation

Run the pinned interpreter directly, or let the script re-exec itself with
hardening flags (see below):

```sh
/Users/tr/.pyenv/versions/3.11.13/bin/python3 -B -E -S -X utf8 \
  /path/to/pigi/tools/pigi-mcp/pigi_oneshot.py <subcommand>
```

| Subcommand | Effect |
| --- | --- |
| `accounts` | `list_accounts {}` scoped to the configured account; returns at most that one account and its provider kind. |
| `search [--since-days N] [--limit M]` | Literal search for the fixed query `Cursor`. `N` defaults to 7 (1–30), `M` defaults to 10 (1–20). Items whose `fromEmail` is not on the sender allowlist are dropped and counted in `filteredOut`. |
| `get <messageID>` | `get_message` for one ID (`^[A-Za-z0-9._@=+-]{1,256}$`). Sender allowlist applies to the returned message, not just search hits. |
| `get-batch <id> [<id> ...]` | 1–5 IDs, one child process and one handshake, sequential `get_message` calls. Per-entry `status` in `results`: `ok`, `"status":"filtered"` (denied sender; no `message`/`text` keys), `not_found`, `error`. |

Not implemented — now or by accident: `list`, `get_verification_code`,
`--account`, `--offset`, `--help`/`-h` (unsupported, exits 2), a caller-chosen
query, send/mark-read/draft or any mutation. Unknown subcommands and unknown
options exit 2. Enabling `list`
requires a code change and its own review, not a config change.

## Output

**stderr is always empty.** Stdout is exactly one JSON document — at most
65,536 ASCII bytes (`ensure_ascii` keeps control and bidi characters escaped) —
on every exit path, success or failure. Merging stdout and stderr therefore
yields the same single JSON document; callers never need to read stderr at all.
Successful results use the envelope
`{"contentTrust":"untrusted","trustNotice":...,"command":<name>, ...}`; every
upstream result is re-checked for `contentTrust == "untrusted"` before use.

`get` with a sender outside the allowlist emits exactly
`{"contentTrust":"untrusted","trustNotice":...,"allowed":false,"message":null}`,
built from scratch — no upstream field is copied, so a denied body, subject,
snippet or sender can never leak through the denial path. `get-batch` uses a
different shape: a denied entry is `{"messageID": ..., "status":"filtered"}`
inside the normal `results` list of the `get-batch` envelope — again with no
message or text keys, and the run exits 3 by the precedence below.

When a serialized payload would exceed 65,536 bytes the wrapper shrinks it by
shape and marks it with `"truncated":true`,
`"truncationNotice":"pigi-oneshot: output truncated at 65536 bytes"` and
`"originalBytes":<full serialized size>`. `search` keeps the longest fitting
prefix of `items` plus `"omittedItems"`; `get` keeps the message metadata and
cuts `text` to the longest fitting character prefix plus `"textTruncated":true`;
`get-batch` cuts every `ok` entry's `text` to a common per-entry character
budget plus `"textTruncated":true` on cut entries, keeping all entries and
statuses. If the result still does not fit — for example metadata fields alone
are huge — the output is the minimal envelope
`{contentTrust, trustNotice, command, truncated, truncationNotice,
originalBytes}` with no mail data, which always fits. Truncated output remains
valid JSON; a successful-but-truncated command exits 8, while an already
non-zero exit code is kept.

## Limits

| Limit | Value |
| --- | --- |
| `--since-days` | 1–30 (default 7) |
| `--limit` | 1–20 (default 10); no `--offset` exists |
| `get-batch` IDs | 1–5, one handshake |
| `messageID` | `^[A-Za-z0-9._@=+-]{1,256}$` |
| stdout | 65,536 bytes, always valid JSON |
| config `account` | non-blank, ≤1024 UTF-8 bytes |
| `senders` | 1–64 exact addresses, each ≤1024 bytes |
| child session | one `pigi_mcp.py` process, 20 s total |

## Exit codes

Every exit code maps to a fixed stdout JSON shape (stderr stays empty):

| Code | Meaning | Stdout shape |
| --- | --- | --- |
| 0 | success | `{"contentTrust":"untrusted","trustNotice":...,"command":<name>, ...}` |
| 2 | usage/validation error (incl. `--help`, which is unsupported) | `{"contentTrust":"untrusted","error":"invalid_arguments"}` |
| 3 | sender not on the allowlist | `get`: the 4-key denial object; `get-batch`: envelope with `filtered` entries |
| 4 | `not_found` | `{"contentTrust":"untrusted","error":"not_found"}` |
| 5 | upstream/transport/MCP error | `{"contentTrust":"untrusted","error":<fixed code>}` |
| 6 | config or environment failure (missing/unsafe config, missing pinned interpreter) | `{"contentTrust":"untrusted","error":"configuration_unavailable"}` |
| 7 | internal error | `{"contentTrust":"untrusted","error":"internal_error"}` |
| 8 | success but output truncated; data incomplete — do not treat as complete | truncated envelope with `"truncated":true` |

`get-batch` maps per-entry outcomes to the worst exit code by precedence
5 > 4 > 3 > 0. Exit 8 applies only when the command would otherwise exit 0; an
already non-zero code (3/4/5) is kept even when the JSON carries
`"truncated":true`.

## Configuration (never committed)

`~/Library/Application Support/pigi/oneshot.json` — regular file, mode exactly
0600, single hard link, owned by the effective user, not a symlink; the parent
directory must be a real directory owned by the user and not group/world
writable. The file is opened `O_NOFOLLOW` and re-`fstat`ed before reading. Any
violation, missing file, malformed JSON or wrong shape fails closed with exit 6.

```json
{"account": "<target-mailbox>", "senders": ["<allowed-sender-1>", "<allowed-sender-2>"]}
```

`senders` is a non-empty list of exact `From` addresses compared
case-insensitively after whitespace trimming — no domains, no wildcards. Use
placeholder-only examples such as `allowed@example.com` when documenting; the
real mailbox and sender addresses stay out of the repo.

## Hardening

On start the script checks whether it already runs with `-B -E -S -X utf8`
(ignore environment, no site, UTF-8 stdio, no `.pyc` writes); if not, it
re-execs the pinned interpreter `/Users/tr/.pyenv/versions/3.11.13/bin/python3`
with those flags and an environment containing only `HOME=/Users/tr` and
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`. A missing pinned interpreter exits 6.
Under `-S` only the script's own directory and the stdlib are importable, which
covers its siblings (`pigi_mcp`, `transport`, `audit`) and nothing else. The
process umask is 077.

The MCP session spawns `pigi_mcp.py --account <configured account> --socket
<default agent.sock> --audit-db <default audit>` as a child with the same
minimal environment; the child's stderr is captured and discarded so it can
never leak into ours. The script itself reads only the config file; it never
opens `mail.db`, the Keychain, the network, or any other file. Writes are
limited to what the adapter itself does (its `tool_calls` audit DB).

## Audit

No new local call log is written by the wrapper (deliberately skipped to avoid
creating another audit object). Every `tools/call` still lands in the adapter's
`~/Library/Application Support/pigi-mcp/audit.sqlite3` and in the App's
`agent_actions` ledger, both content-free.

## Residual risks

- This is application-layer scoping, not a security boundary: any process
  running as the same macOS user can call `agent.sock` directly or run the
  unscoped adapter. It narrows what the *approved channel* can request; it does
  not isolate the channel from other same-UID code.
- The allowlist matches the stored `From` header, which sender-controlled mail
  can spoof; it is not sender authentication unless the upstream verifies it.
- `search --limit` applies upstream before allowlist filtering, so a result can
  contain fewer than `limit` items (the rest counted in `filteredOut`).
- `get-batch` is the only multi-call path: at most 5 `get` calls behind one
  handshake, sequential, same child.
- Output is always valid JSON; incomplete data is marked by
  `"truncated":true`/`"textTruncated":true`/`"omittedItems"` and exit 8 —
  callers must check the flags and code, not assume completeness.
- Command output enters the caller's transcript/context; mail fields remain
  `untrusted` data and must never be executed or elevated to instructions.
- Exit 5 covers any upstream, transport or MCP failure; the fixed `error` codes
  come from the protocol-v1 set plus `invalid_response`/`upstream_unavailable`.
