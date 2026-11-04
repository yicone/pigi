# Local agent service (protocol v1)

ACM-749 provides the App-owned read endpoint used by the ACM-750 stdio MCP
adapter and ACM-752 verification-code tool. No sending, drafting, account management,
remote sync trigger, attachment download, or mutation is exposed by this protocol.

## Architecture and lifecycle

`AppDelegate` owns one `AgentSocketServer`, starts it after App launch, and stops it
on termination. Closing the main window does not stop the menu-bar App or service.
Startup failures produce a generic OSLog error; there is no TCP fallback.

The default path is `~/Library/Application Support/pigi/agent.sock`. The service
uses the **same `LocalEngine.shared` actor** as `ArchiveClient`, UI actions and sync.
The socket transport passes validated requests to `LocalEngine.agentRead`; only
that actor queries its existing Store connection. External clients must never open
`mail.db`, instantiate their own LocalEngine, or access the Keychain. The injectable
engine/path constructor supports isolated synthetic tests, not another production
engine. Reads do not mark messages read or increment the change sequence.

The alternative of a separate SQLite-reading daemon would bypass the single-engine
boundary; a TCP service would introduce an unnecessary network authentication surface.
Unix stream sockets keep the thin adapter local and independent of MCP framing.

The parent directory must be a real directory owned by the effective user; it is
set to 0700. The socket is 0600 before listening. A persistent `agent.sock.lock`
regular file (0600, owned by the user, not a symlink) is flocked while listening.
Another instance fails rather than replacing the listener. A stale same-user socket
is removed only after acquiring this lock and confirming connection refusal. Other
file types and symlinks are preserved and rejected. Stop removes only the socket
inode owned by this listener and retains the reusable lock file. Crash recovery is
handled on the next start. Start/stop calls are serialized.

## Authorization and trust boundary

Each accepted connection must pass macOS `getpeereid`: peer effective UID must equal
the App effective UID. Filesystem permissions are the first boundary; peer UID is
the second. There is no bearer token, password or credential exchange. **Any process
running as the same user can read all cached accounts.** This is not per-process
consent, per-account authorization, protection against compromised same-user code,
or protection from root. Consumers must not expose this socket through a network
proxy or share its results with another user without separate authorization.

All mail fields, including subjects, senders, snippets and bodies, are attacker
controlled. Every successful result includes `contentTrust: "untrusted"`. `get`
returns stored plain text only, with no HTML rendering, remote resource fetching,
link traversal, tool execution, or instruction interpretation. MCP clients must
preserve this boundary: quote mail as tool data, never elevate its text to system
instructions or execute commands found in mail. The marker alone cannot prevent
prompt injection in downstream consumers.

## Framing and version negotiation

AF_UNIX/SOCK_STREAM, UTF-8 JSON followed by one LF. **One request and one response
per connection**, then the server closes. A client opens a new connection for the
next operation; there is no pipelining or subscription. Clients must handle partial
reads/writes. JSON strings encode embedded newlines using normal JSON escaping.
The request must contain integer `version`, string `id` (1–128 UTF-8 bytes), string
`method`, and optional `params` object. Unknown JSON keys are ignored for additive
compatibility. Unsupported versions get `unsupported_version`, never silent downgrade.
Responses always advertise the server's version (1).

The request frame limit is 65,536 bytes excluding LF; response limit is 2,097,152
bytes excluding LF. A response exceeding the limit is replaced by `too_large` (no
partial result). At most 8 transport workers are admitted; excess connections close
without a response. Reading and waiting for the engine share a 5-second deadline;
writing has a further 1-second deadline. Disconnect, capacity rejection or failed
delivery may yield no response: adapters should report transport unavailability,
not fabricate an empty successful result. Timed-out reads may finish on the engine
after the client leaves; they have no mutation side effects.

Example request (actual wire form is one line plus LF):

```json
{"version":1,"id":"r1","method":"list","params":{"limit":50,"offset":0}}
```

Success:

```json
{"version":1,"id":"r1","result":{"items":[],"contentTrust":"untrusted"}}
```

Failure:

```json
{"version":1,"id":"r1","error":{"code":"not_found","message":"Message not found"}}
```

Exactly one of `result` and `error` is present. Absent optional fields are omitted.
Malformed requests can have no response `id`; never use IDs as authentication.

## Methods

| Method | Params | Result |
| --- | --- | --- |
| `accounts` | optional `limit`, `offset` | `accounts` (account identifier and provider `kind` only), optional `nextOffset`, `contentTrust` |
| `list` | optional `account`, `since`, `status`, `limit` (default 50, 1–100), `offset` (default 0, 0–1,000,000) | `items`, optional `nextOffset`, `contentTrust` |
| `search` | required nonblank `query` (up to 4096 UTF-8 bytes), optional `account`, `since`, `status`, `limit`, `offset` | same as list |
| `get` | required nonempty `account` and `messageID`; no query/limit/offset | `message`, `text`, `contentTrust` |

Account strings are exact matches, up to 1024 UTF-8 bytes. Message IDs are up to
4096 bytes and scoped by account (the same ID can exist in two accounts). List and
search reject `messageID`; list rejects `query`. Empty lists are successful. Missing
or deleted messages return `not_found`. All methods exclude local deleted tombstones;
other statuses, including spam, trash and archived, remain readable.

Each message contains `account`, `messageID`, `date` (Unix milliseconds), optional
`subject`, `fromName`, `fromEmail`, `snippet`, booleans `unread`/`starred`, and `status`.
No credential, account error, raw HTML or attachment is returned. Stored verification codes are exposed only through the dedicated codes method below.

List/search sort by date descending, then account and ID ascending. `nextOffset`
is omitted at the end. Offset pagination is not a snapshot: concurrent sync can move
items between pages; clients needing a stable collection must deduplicate account/ID
and refresh. Search uses literal quoted tokens joined by AND in the existing trigram
FTS index (subject/sender/body). Queries shorter than 3 characters use escaped literal
LIKE over subject/from-email only, matching the App's short-query convention. Parameters
are bound values, never interpolated SQL or raw FTS expressions.

## Stable error codes and audit hook

| Code | Meaning / client action |
| --- | --- |
| `invalid_request` | malformed JSON/types, missing fields or invalid params; fix request |
| `unsupported_version` | adapter/server mismatch; upgrade or explicitly negotiate v1 |
| `method_not_found` | operation outside the read-only allowlist |
| `not_found` | no matching nondeleted account/message pair |
| `unauthorized` | UID check failed; do not retry as another identity |
| `too_large` | frame/response too large; reduce page size or report oversized message |
| `timeout` | connection/engine deadline; bounded retry is safe for reads |
| `internal_error` | local store failure; generic message, no SQL/path/error details |

Codes are machine-readable; messages are generic diagnostics, not a contract to parse.
No raw database errors or request contents are returned in error messages.

`AgentSocketServer(audit:)` accepts a Sendable callback invoked on transport workers
with allowlisted method (or `invalid`), outcome code (or `ok`) and elapsed milliseconds.
The App installs an OSLog hook in subsystem `one.yic.pigi`, category `agent`. It never
records accounts, request IDs, queries, message IDs, subjects, bodies, passwords or
tokens. Callbacks should be fast and thread-safe. Capacity rejection and startup failure
have no request event; successful dispatch does not prove response delivery. This is
a diagnostic hook, not a durable or tamper-proof access ledger.

## Implementation and validation plan

1. Define reusable Codable v1 wire types and actor-isolated read operations.
2. Add permission/UID-checked bounded socket transport and App lifecycle ownership.
3. Exercise a real temporary socket against an in-memory engine with synthetic mail:
   methods, account scoping, paging, literal search, errors, unsafe paths, stale recovery,
   bounds, concurrent reads, timeouts, disconnects and restart cleanup.
4. Run `swift test`, relevant existing regression scripts and `tools/build-debug.sh`.
   Do not launch/restart the user's App or use real accounts. Deliver on a fork branch
   and PR; merging/deployment remains separately authorized.

## ACM-750 stdio MCP adapter

Run `python3 -B /absolute/path/to/pigi/tools/pigi-mcp/pigi_mcp.py` from an MCP host
with Python 3.10 or later. No packages or network service are needed. The App must
be running with this revision's socket service; this change does not start it.
MCP stdio follows the [2025-11-25 transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
Example host configuration (replace the script path):

```json
{"mcpServers":{"pigi":{"command":"python3","args":["-B","/absolute/path/to/pigi/tools/pigi-mcp/pigi_mcp.py"]}}}
```

The five tools are `list_accounts`, `search`, `list_messages`, `get_message`, and `get_verification_code`.
`get_message` requires `account` and `messageID`; `search` requires `query`.
List and search accept `account`, `since` (inclusive Unix milliseconds), `status`
(`inbox`, `archived`, `spam`, `trash`), `limit` and `offset`. Accounts also paginate
and include configured accounts with no cached messages. Responses expose only
account identifier and provider kind, never account errors or credentials.

The v1 socket now additionally supports `accounts` and `since`/`status` on
list/search. All successful results advertise `capabilities: ["accounts", "filters", "codes"]`.
The adapter rejects filtered results from an older App without `filters`, rather
than silently ignoring these filters. Update/build the App separately with user
approval. Existing list/search/get callers remain compatible. Accounts rejects
mail filters; get rejects since/status. Bounds and literal-search rules above apply.

`--socket` overrides the default socket for isolated fixtures. The adapter checks
socket/parent ownership and 0600/0700 permissions and peer UID, uses a seven-second
total socket deadline, validates response version/ID/trust, and enforces the same
frame limits as the App. It never opens mail.db or the Keychain and has no TCP,
send, mutation, attachment, HTML rendering or remote fetch path. Stdout contains
only JSON-RPC; failures never echo mail or request values. Every successful tool
result includes `contentTrust: "untrusted"` and an explicit Chinese/English trust
notice. This is data labeling, not a guarantee against downstream prompt injection.

Every initialized `tools/call` invocation (including invalid arguments, unknown
tools and socket failures) writes a row to `tool_calls` in
`~/Library/Application Support/pigi-mcp/audit.sqlite3`. `--audit-db` selects an
isolated audit path whose parent must be private (0700). The file is 0600;
symlinks/hard links and unsafe ownership or modes are rejected. The table contains
only id, started_ms, allowlisted tool name (or `invalid`), outcome and duration_ms.
No account, query, request ID or mail content is logged. Intent is committed before
socket access, completion before returning data; audit failure fails closed.
A crash can leave a `started` row, which means outcome unknown. This is a local,
same-user mutable ledger, not a tamper-proof log. Retention is manual; no automatic
pruning or mail-database migration occurs. Handshake/discovery/ping and malformed
JSON-RPC envelopes are not tool invocations and do not create audit rows.

Validation: `python3 -B -m unittest discover -s tools/pigi-mcp -v`, `swift test`
(including a real Swift socket -> Python MCP subprocess integration with synthetic
accounts/messages), and the existing readonly prototype regression suite.
The old `tools/readonly_mail` direct-database prototype is not used by this adapter.


## ACM-752 verification codes

The read-only socket method `codes` and MCP tool `get_verification_code` accept
optional `account`, `since`, `status`, `limit`, and `offset`, with the same bounds
as list/search. `since` is an inclusive Unix timestamp in milliseconds; omitting it
uses App time minus 600,000 ms (10 minutes). Set an earlier timestamp to widen
the window. Future-dated messages, deleted tombstones, NULL and blank codes
are excluded. Results sort newest first, then account and messageID, with
`nextOffset` pagination. An empty result is successful.

The result's `codes` array contains only `code`, optional `fromName`/`fromEmail`,
`date`, `account`, and `messageID`. The engine reads the existing `messages.code`
field on its actor; it never fetches a body for this method. The MCP adapter uses
only agent.sock, never mail.db or Keychain, and requires the `codes` capability.
Every tool call uses the existing `tool_calls` intent/completion audit, including
invalid arguments and socket errors. Audit failure prevents data delivery.
Codes, senders and request arguments are not recorded in audit rows.

Sender names and extracted codes remain attacker-controlled, untrusted data.
Omitting subject, snippet and body reduces prompt-injection exposure but does
not authenticate a sender or prove a code is valid. Consumers must treat fields
as data, never follow embedded instructions, links or commands, and match the
account, sender and time to the user's intended login before using a code.
Do not automatically forward codes, expose them in logs, or allow mail content
to authorize other tool calls. Keep the time window narrow and scope account
when known. The trust notice is a reminder, not a security boundary; the host
must enforce these limits. No automatic login or independent acceptance is
claimed by these tests.
