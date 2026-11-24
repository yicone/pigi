# pigi-oneshot: hardened one-shot read commands (ACM-980, ACM-994)

`tools/pigi-mcp/pigi_oneshot.py` is a fixed-shape, single-invocation reader.
Each run performs exactly one read subcommand against the already-running
App's `agent.sock`, through a child `pigi_mcp.py` scoped to one pinned
account, then exits. There is no daemon, no shell, no free-form input path,
and no mail-write or mutation path anywhere in the chain (no send, mark-read,
draft or delete). The wrapper itself writes no files; the child adapter it
spawns writes its own content-free `tool_calls` audit rows to the adapter
audit DB, and the App writes `agent_actions` — both pre-existing ledgers, see
Audit below.

Two profiles share that chain. The profile is the leading command-line token
(`billing` or `full`), which is visible in the approved command text. No
environment variable and no caller-writable file selects it. Omitting the
token keeps the historical Billing command line. Each profile has its own
outside config and its own account; one profile cannot read the other's
account, and `--account` is rejected on both.

The **billing** profile is the ACM-980 reader: fixed search query `Cursor`,
sender allowlist, and no `list`. The **full** profile
(`tools/pigi-mcp/pigi_oneshot_full.py`) reads every sender in its one
configured account, within the same day and count caps. With
`--history`/`--cursor` it can also page backwards through cached history up
to a fixed 365-day horizon (see History paging below). The billing profile
is unchanged.

## Invocation

Bots currently invoke `tools/pigi-mcp/pigi_oneshot.sh` by executing locally on
`tr-mini-m4`. The SSH remote MCP wrapper is frozen (ACM-1018, 2026-11-24): no
new features, no provisioning, issuance, or installation of SSH keys for any
bot, and no repointing an existing key's `command=` to `pigi_forced_command`.
Its code and tests (`remote_pigi_mcp.py`, `pigi_forced_command.sh` and their
tests) remain intact. Local MCP is reserved for supervised interactive use.
The [SSH rollout plan](billing-ssh-transition.md) is paused; unfreezing or
resuming it requires separate user approval by issue number.

The **only** supported launch is the launcher script (this is the command text
the approver sees):

```sh
<checkout>/tools/pigi-mcp/pigi_oneshot.sh <subcommand> …
<checkout>/tools/pigi-mcp/pigi_oneshot.sh billing <subcommand> …
<checkout>/tools/pigi-mcp/pigi_oneshot.sh full <subcommand> …
```

The first two forms are the billing profile. They behave the same, including
output and exit codes, so the deployed Billing command line does not change.
`full` is the only other profile name. Any other leading token is rejected
with exit 2 before the config file or `agent.sock` is touched. `full` as a
later argument is not a profile: `get full` on the billing command line is a
message id.

Running `python3 pigi_oneshot.py` directly — or through any other interpreter
command line — is refused with exit 9. The reason: a Python interpreter runs
its site hooks (`sitecustomize`, `usercustomize`, `.pth` files, `PYTHONPATH`
modules) *before* the script's first line, so no in-script check can undo that;
entry has to be controlled outside the script. The launcher therefore scrubs
the environment with `env -i`, runs a pinned interpreter with
`-I -S -B -X utf8`, and marks the run with the trusted-entry flag the script's
gate requires (see Hardening).

The launcher must be executed **directly** — `./pigi_oneshot.sh` or
`/bin/sh pigi_oneshot.sh`. Wrapping it in bash — `bash pigi_oneshot.sh`,
`bash -c "…pigi_oneshot.sh…"`, `/bin/bash <launcher>` — is **forbidden**: bash
reads `$BASH_ENV` before the script's first line, which no launcher code can
prevent. `/bin/sh` and direct execution do not trigger `BASH_ENV` (observed on
macOS).

| Subcommand | Billing | Full |
| --- | --- | --- |
| `accounts` | `list_accounts {}` scoped to the billing account. | Same, scoped to the full-profile account. A response that names any other account is refused. |
| `list [--since-days N \| --history \| --cursor T] [--limit M]` | Rejected (exit 2). | Newest cached mail in the window. `N` defaults to 7 (1–30), `M` defaults to 10 (1–20 per page). No sender filter. `--history`/`--cursor` page backwards, see below. |
| `search --query <text> [--since-days N \| --history \| --cursor T] [--limit M]` | Literal search for the fixed query `Cursor`. Items whose `fromEmail` is not on the sender allowlist are dropped and counted in `filteredOut`. | Requires `--query <text>`. The query is the caller's, not `Cursor`. No sender filter and no `filteredOut`. `--history`/`--cursor` page backwards, see below. |
| `get <messageID>` | `get_message` for one ID (`^[A-Za-z0-9._@=+-]{1,256}$`). Sender allowlist applies to the returned message, not just search hits. | Same ID rule. Any sender in the configured account is returned. A message whose `account` is not that account is refused. |
| `get-batch <id> [<id> ...]` | 1–5 IDs, one child process and one handshake, sequential `get_message` calls. Per-entry `status` in `results`: `ok`, `"status":"filtered"` (denied sender; no `message`/`text` keys), `not_found`, `error`. | Same batch cap and handshake. No `"status":"filtered"`; a foreign account is `error` / `invalid_response` and its body is not copied. |
| `codes [--since-minutes N] [--limit M] [--offset O] [--status S] [--from-email A ...]` | Rejected (exit 2). | Cached verification codes in the configured account, newest first. See Verification codes below. |

`--offset` exists only on `full codes`; the MCP tool `get_verification_code`
is reachable only through that one subcommand — `full codes` is the sole
caller that starts its `pigi_mcp.py` child with `--enable-codes`, and the
remote wrapper and the SSH forced command never pass it, so a pinned remote
adapter still rejects `get_verification_code` like any other unknown tool.
Not implemented on either profile — now or by accident: `--account`,
`--help`/`-h` (unsupported, exit 2; only `get`/`get-batch` read them as IDs),
send/mark-read/draft or any mutation. The billing profile also rejects
`list`, `codes` and a caller-chosen query, and has no path to verification
codes at all. Unknown subcommands, unknown options, and an unknown profile
exit 2 before config or socket use. The full profile's `list` is a code path,
not a config switch.

### IDs that start with `-`

`get` and `get-batch` take IDs only and no options, so every token must match
the `messageID` rule and nothing else is interpreted (both profiles, and
through `pigi_oneshot.sh`). Any valid ID is passed as is, with no `--`:
`get -abc`, `get -`, `get --limit`, `get-batch ok -a --b --history`.
A first `--` token is always the separator and is dropped (`get -- -abc`,
`get-batch -- -a b`). A literal `--` is never an ID, in any position: a lone
`--` (`get --`, `get-batch --`) leaves no ID, and any `--` after the
separator or anywhere else in the batch (`get -- --`, `get-batch a --`,
`get-batch -- -- a`) is rejected. All of these exit 2 with zero upstream
requests.

Because those tokens are IDs, not options, `get`/`get-batch` no longer reject
them as paging options: `get-batch m1 --history` is a batch of two IDs. `get`
with more than one token still exits 2. Invalid IDs, a missing ID, any `--`
token (see above), more than one ID for `get` and more than 5 for `get-batch`
exit 2 with zero upstream requests.

### History paging (full only)

On full `list` and `search`, exactly one of `--since-days`, `--history`,
`--cursor <token>` may be given. Any combination, a repeated flag, or either
paging option on `accounts` or on the billing profile exits 2 before config or
socket use (on `get`/`get-batch` those tokens are IDs, see above):

```sh
<checkout>/tools/pigi-mcp/pigi_oneshot.sh full list --history --limit 20
<checkout>/tools/pigi-mcp/pigi_oneshot.sh full list --cursor <token> --limit 20
<checkout>/tools/pigi-mcp/pigi_oneshot.sh full search --query "<text>" --history
<checkout>/tools/pigi-mcp/pigi_oneshot.sh full search --query "<text>" --cursor <token>
```

`--history` starts a paged read at the newest cached mail with a hard-coded
365-day `since` bound (`HISTORY_MAX_DAYS` in code, not configurable).
`--cursor` continues a paged read. Each call emits up to `--limit` items
(default 10, max 20) plus a page envelope
`"page":{"end":<bool>,"nextCursor":<string|null>}`. While `end` is false,
repeat the call with `--cursor <nextCursor>`; `end:true` — possibly with
empty `items` — is the explicit termination signal. Each page is one upstream
call (one child session). Non-paged `list`/`search` output is byte-for-byte
unchanged and carries no `page` key.

The cursor is an opaque URL-safe base64 token (≤1024 characters) carrying the
paging state, bound to the subcommand — and for `search`, to the exact query
text. A malformed, truncated, foreign-command, wrong-query, or out-of-bounds
cursor exits 2 with zero upstream calls; the bounds are `o >= 1` (offsets
start at 1), `s <= d <= 9007199254740991` (the anchor date lies inside the
saved window and inside the server's millisecond range), and `i` matching the
`messageID` rule `get` uses. A cursor's `s` must
also match a horizon minted by `--history` within the last 6 hours
(`now−365d−6h <= s <= now−365d+60s`, allowing one minute of clock skew), so a
paged walk must finish within 6 hours of `--history`; later or foreign-window
cursors exit 2 and the caller restarts with `--history`. If the mailbox
shifted so far that the saved position can no longer be located — more than
roughly 40 rows moved before the anchor — the run fails closed with
`{"contentTrust":"untrusted","error":"cursor_stale"}` (exit 5) and no items;
restart with `--history`.

A paged page never uses the item-dropping shrink: the wrapper emits a shorter
prefix and recomputes the cursor, so no item is skipped. If a single item
alone exceeds the 65,536-byte cap it is still delivered: its non-identity
string fields (never `account`, `messageID`, or `date`) are cut to a common
character budget so the page fits, the item carries
`"truncatedFields":[<sorted names>]`, and the page is the normal paged
envelope plus `"truncated":true`, `"truncationNotice"`, and `"originalBytes"`,
exiting 8 — message identity is delivered, nothing is skipped, and callers
can fetch the full text with `get <messageID>`. If the item still cannot fit
with every cuttable field cut to 0 characters — for example a huge
non-string field — the run fails closed with
`{"contentTrust":"untrusted","error":"page_item_too_large"}` (exit 5), no
items and no cursor: the walk deliberately cannot continue past an
undelivered message through this channel. Message IDs carry one contract —
the `^[A-Za-z0-9._@=+-]{1,256}$` rule `get` already uses: a page whose items
include a messageID that fails it fails closed with `invalid_response`
(exit 5), no items and no cursor — the walk deliberately cannot continue past
a message whose body `get` could never fetch, and a cursor cannot be anchored
on one either (real mailbox IDs are not claimed to conform).

### Verification codes (`full codes` only)

`full codes` reads cached verification codes through the dedicated
`get_verification_code` tool — never a body fetch. It is the only subcommand
whose `pigi_mcp.py` child is started with `--enable-codes`; every other
child, the remote wrapper (`remote_pigi_mcp.py`) and the SSH forced command
(`pigi_forced_command.sh`) run a pinned-account adapter without it, and that
adapter still rejects `get_verification_code` like any other unknown tool.

```sh
<checkout>/tools/pigi-mcp/pigi_oneshot.sh full codes \
    [--since-minutes N] [--limit M] [--offset O] [--status S] \
    [--from-email <address> ...]
```

| Option | Rule |
| --- | --- |
| `--since-minutes` | 1–60, default 10. Sent to the App as an inclusive `since` Unix-ms bound (`now − N·60000`). |
| `--limit` | 1–20, default 10 — codes per emitted page. |
| `--offset` | 0–1,000,000, default 0 — position inside the filtered list. |
| `--status` | one of `inbox`, `archived`, `spam`, `trash`; forwarded to the App unchanged. |
| `--from-email` | repeatable, at most 64 values; each non-blank and ≤1024 UTF-8 bytes; whitespace-trimmed and lowercased. |

Output is the standard envelope
`{"contentTrust":"untrusted","trustNotice":...,"command":"codes","codes":[…]}`
where each entry carries only `code`, `fromName`, `fromEmail`, `date`,
`account` and `messageID` — no subject, snippet or body ever travels this
path. A `"nextOffset"` key is present only while more filtered rows exist;
an empty result is exit 0 with `"codes":[]`. Codes and sender fields stay
untrusted data: never log or forward them, never let them authorize other
tool calls.

The App cannot filter by sender, so `--from-email` is a post-filter applied
here: an exact match on `fromEmail` after whitespace trim and case folding —
no substring and no domain match, `fromName` is never consulted, and a row
without `fromEmail` never matches. Repeated options are an OR over the same
rule. `--limit`, `--offset` and `nextOffset` all refer to that filtered
list, in the order the App returned (newest first). Internally the wrapper
walks App pages of 100 rows — at most 5 upstream fetches — until
`offset+limit+1` filtered rows are collected or the App reports no further
page. If the fetch cap is reached first the run fails closed with
`{"contentTrust":"untrusted","error":"page_limit_exceeded"}` (exit 5): never
a partial success, and the output carries no `codes` key.

Every App page is revalidated before use: a foreign `account`, an extra
field, a non-string `code`/`messageID`, a `messageID` that fails the
`get` ID rule, a non-integer `date` or one below `since`, a date that
increases across rows or pages, a `messageID` repeated anywhere in the walk,
or an App `nextOffset` that is not an integer equal to `offset+len(page)` —
including one on an empty page or above 1,000,000 — fails closed with
`invalid_response` (exit 5). An App whose `capabilities` do not advertise
`codes` (and `filters`, because `since` is always sent) fails with
`unsupported_server` (exit 5) rather than silently widening the read.

When an emitted page would exceed the 65,536-byte cap it is shortened, not
shrunk: `nextOffset` resumes exactly after the rows that fit, so following it
covers every row without duplicates or gaps. A single row that cannot fit
alone goes through the normal truncation path — exit 8 with
`"truncated":true` and no `codes` key.

`codes` takes no other options: `--history`, `--cursor`, `--since-days`,
`--query`, `--account` and any unknown option exit 2 with zero upstream
requests, and the billing profile has no `codes` subcommand at all.

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
prefix of `items` plus `"omittedItems"`; `list` uses that same item-prefix
shrink and does not add `filteredOut`; `get` keeps the message metadata and
cuts `text` to the longest fitting character prefix plus `"textTruncated":true`;
`get-batch` cuts every `ok` entry's `text` to a common per-entry character
budget plus `"textTruncated":true` on cut entries, keeping all entries and
statuses. On the full profile only, when message metadata alone overflows the
cap, `get`/`get-batch` retry once with every message's non-identity string
fields cut to 512 characters (`account`, `messageID`, `date` are never cut)
and marked `"truncatedFields"` on the message — identity plus `text` are
still delivered, so a message a paged page cut is recoverable through
`get <messageID>`; if the body is also huge, `text` is prefix-cut with
`"textTruncated":true` as usual. If the result still does not fit — for
example a huge non-string field — the output is the minimal envelope
`{contentTrust, trustNotice, command, truncated, truncationNotice,
originalBytes}` with no mail data, which always fits; that residual is not
recoverable through this channel. Truncated output remains
valid JSON; a successful-but-truncated command exits 8, while an already
non-zero exit code is kept.

## Limits

| Limit | Value |
| --- | --- |
| `--since-days` | 1–30 (default 7), both profiles; mutually exclusive with `--history`/`--cursor` on full. There is no all-time read. |
| `--limit` | 1–20 (default 10), per call or per page; `--offset` exists only on `full codes` |
| full `--history` | pages `list`/`search` backwards from newest; hard 365-day `since` bound, fixed in code |
| full `--cursor` | opaque token, ≤1024 characters; bound to the subcommand and, for `search`, the query; usable for 6 hours after `--history` (`o>=1`, `s<=d<=9007199254740991`, horizon-pinned), then exit 2 — restart with `--history` |
| full `--query` | required; 1–128 characters and ≤256 UTF-8 bytes; each character is Unicode category L or N, or one of space `.` `_` `+` `@` `-`. Control characters, quotes, slashes and other punctuation are rejected. The value is forwarded unchanged. |
| `get-batch` IDs | 1–5, one handshake |
| `messageID` | `^[A-Za-z0-9._@=+-]{1,256}$` |
| stdout | 65,536 bytes, always valid JSON, both profiles |
| config `account` | non-blank, ≤1024 UTF-8 bytes |
| billing `senders` | 1–64 exact addresses, each ≤1024 bytes |
| child session | one `pigi_mcp.py` process, 20 s total |

Out-of-range days, limits, batch size, or an illegal full-profile query exit 2
and do not open the config or the socket. `list` and `search` always send a
`since` bound, so an App that does not advertise `filters` fails closed
instead of returning an unfiltered history.

## Exit codes

Every exit code maps to a fixed stdout JSON shape (stderr stays empty):

| Code | Meaning | Stdout shape |
| --- | --- | --- |
| 0 | success | `{"contentTrust":"untrusted","trustNotice":...,"command":<name>, ...}` |
| 2 | usage/validation error (incl. `--help`, which is unsupported); also a paging-option combination, a malformed/expired/foreign `--cursor`, or a paging option on the billing profile | `{"contentTrust":"untrusted","error":"invalid_arguments"}` |
| 3 | billing only: sender not on the allowlist. The full profile has no allowlist and does not use this code | `get`: the 4-key denial object; `get-batch`: envelope with `filtered` entries |
| 4 | `not_found` | `{"contentTrust":"untrusted","error":"not_found"}` |
| 5 | upstream/transport/MCP error; also `cursor_stale` (a paged read whose anchor moved out of reach), `page_item_too_large` (a paged item that cannot be delivered even with all text fields cut — the walk cannot continue past it, by design nothing is skipped) — restart with `--history` — and `page_limit_exceeded` (a `codes` read that could not decide within 5 App fetches — never a partial success) | `{"contentTrust":"untrusted","error":<fixed code>}` |
| 6 | config or environment failure — missing/unsafe config, missing pinned interpreter, or pinned interpreter fails to execute (exec status 126/127, normalized by the launcher) | `{"contentTrust":"untrusted","error":"configuration_unavailable"}` |
| 7 | internal error — also an interpreter crash/signal or any unexpected child status, normalized by the launcher | `{"contentTrust":"untrusted","error":"internal_error"}` |
| 8 | success but output truncated; data incomplete — do not treat as complete. On a paged page it means one item's text fields were cut (`truncatedFields`): message identity delivered, nothing skipped — use `get <messageID>` for the full text | truncated envelope with `"truncated":true` |
| 9 | untrusted entry — not launched by `pigi_oneshot.sh` | `{"contentTrust":"untrusted","error":"untrusted_entry"}` |

`get-batch` maps per-entry outcomes to the worst exit code by precedence
5 > 4 > 3 > 0. Exit 8 applies only when the command would otherwise exit 0; an
already non-zero code (3/4/5) is kept even when the JSON carries
`"truncated":true`.

## Configuration (never committed)

Both files live in `~/Library/Application Support/pigi/`, are regular files,
mode exactly 0600, a single hard link, owned by the effective user, and not
symlinks. The parent directory must be a real directory owned by the user and
not group/world writable. Each file is opened `O_NOFOLLOW` and re-`fstat`ed
before reading. A missing file, bad mode, extra link, symlink, malformed JSON,
or the other profile's shape fails closed with exit 6. A broken full-profile
file does not change billing, and the reverse is also true. Neither file is
written by this repository.

| Profile | Path | Shape |
| --- | --- | --- |
| billing | `oneshot.json` | `{"account","senders"}` only |
| full | `oneshot-full.json` | `{"account"}` only |

```json
{"account": "<billing-mailbox>", "senders": ["<allowed-sender-1>", "<allowed-sender-2>"]}
```

```json
{"account": "<full-mailbox>"}
```

Billing `senders` is a non-empty list of exact `From` addresses compared
case-insensitively after whitespace trimming — no domains, no wildcards. The
full profile has no sender list; a file that includes `senders` is refused.
Use placeholder-only examples such as `allowed@example.com` and
`full@example.net` when documenting; the real mailbox and sender addresses
stay out of the repo. The deployed full-profile account is the Proton target
account, written outside this repository by a later change. This document
does not create that file.

## Hardening

`pigi_oneshot.sh` (POSIX sh, mode 0755) fixes `PATH`, resets `IFS`, sets umask
077 and unsets every interpreter-influencing variable (`BASH_ENV`, `ENV`,
`CDPATH`, all `PYTHON*`). It then `exec env -i` a pinned interpreter
(`/Users/tr/.pyenv/versions/3.11.13/bin/python3`) with a whitelisted
environment — `HOME`, `PATH`, `LANG`, `LC_ALL`, and the flag
`PIGI_ONESHOT_LAUNCHER=trusted-entry-v1` — and the flags `-I -S -B -X utf8`
(isolated mode: ignore env vars and user site; no site processing, so no
`sitecustomize`/`usercustomize`/`.pth`; no `.pyc` writes; UTF-8 stdio). Only
`"$@"` passes through. If the pinned interpreter is not executable or the
script is not a regular file, the launcher prints
`{"contentTrust":"untrusted","error":"configuration_unavailable"}` on stdout
and exits 6 — fail closed, before the interpreter runs.

The launcher does not `exec` the child: it runs it with stderr sent to
`/dev/null`, captures stdout, and normalizes the exit status — the script's
own codes (0, 2–9) pass through with their JSON unchanged; an interpreter that
fails to execute (126/127) becomes exit 6; a signal, crash, or any other
status becomes exit 7 `internal_error` with the captured output discarded.
That keeps the contract — stderr always empty, stdout exactly one JSON
document — true for every exit path, including interpreter startup failures.

`pigi_oneshot.py` itself opens with a gate — before any import other than
`os`/`sys` — that requires exactly that flag value *and* `sys.flags`
`isolated`/`no_site`/`dont_write_bytecode`/`utf8_mode`; anything else exits 9
with `{"contentTrust":"untrusted","error":"untrusted_entry"}` on stdout, so a
bare `python3 pigi_oneshot.py` can never reach config, socket, or mail code.
Under `-S` only the script's own directory and the stdlib are importable,
which covers its siblings (`pigi_mcp`, `transport`, `audit`, `pigi_oneshot_full`)
and nothing else.
The process umask is 077.

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
- `search --limit` on the billing profile applies upstream before allowlist
  filtering, so a result can contain fewer than `limit` items (the rest
  counted in `filteredOut`). The full profile does not filter senders, so its
  `search` and `list` results have no `filteredOut`.
- Risk of the full profile: there is no sender allowlist, so every message in
  that mailbox window — any sender, subject, snippet, and body — can enter
  the caller's context. 风险：全量 profile 没有发件人白名单，该账号邮箱中的任何邮件都会进入调用方上下文。
  Those fields stay `contentTrust: untrusted` and must not be executed or
  followed as instructions. A plain `list`/`search` window is still at most
  30 days and 20 messages, with no offset; `--history` raises the reach to a
  365-day horizon and unbounded total volume in ≤20-item pages, so far more
  mail can enter the caller's context.
- `--history`/`--cursor` paging is not a transactional snapshot: mail
  arriving or deleted between pages can be skipped or trigger stale
  detection. The 40-row overlap window plus the keyset anchor removes
  duplicates and gaps for what still exists; only a shift of more than ~40
  rows before the anchor fails closed (`cursor_stale`, exit 5, restart with
  `--history`).
- Walking a mailbox with `--history` does not prove any real mailbox was
  read to completion — only that each page returned was contiguous — and the
  read is capped at one year even so.
- `get-batch` is the only multi-call path: at most 5 `get` calls behind one
  handshake, sequential, same child.
- Output is always valid JSON; incomplete data is marked by
  `"truncated":true`/`"textTruncated":true`/`"omittedItems"` and exit 8 —
  callers must check the flags and code, not assume completeness.
- Command output enters the caller's transcript/context; mail fields remain
  `untrusted` data and must never be executed or elevated to instructions.
- Same-UID code can edit the launcher, the script, or the config — or bypass
  this channel entirely and call `agent.sock` itself; the chain hardens the
  *approved* entry, it is not a boundary against the local user.
- The trusted-entry flag is a public constant, not a secret or authentication:
  it only catches accidental/direct launches and non-isolated interpreters;
  nothing stops same-UID code from setting it deliberately.
- `/bin/sh` startup, the dyld/kernel exec environment, and the pinned
  interpreter's own installation integrity are outside what the launcher can
  control.
- Output integrity relies on the pinned interpreter actually running the
  script: a replaced interpreter that exits 0 or 2–9 with arbitrary stdout is
  not detected — only exec failure (126/127) and crashes are normalized.
- The pinned literals inside `pigi_oneshot.sh` must be edited only as rendered
  values at rollout (the installed copy is never edited in place by tests).
- Exit 5 covers any upstream, transport or MCP failure; the fixed `error` codes
  come from the protocol-v1 set plus `invalid_response`/`upstream_unavailable`.
