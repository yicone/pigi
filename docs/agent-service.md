# Local agent service (protocol v1)

ACM-749 provides the App-owned read endpoint used by the future ACM-750 stdio MCP
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
| `list` | optional `account`, `limit` (default 50, 1–100), `offset` (default 0, 0–1,000,000) | `items`, optional `nextOffset`, `contentTrust` |
| `search` | required nonblank `query` (up to 4096 UTF-8 bytes), optional `account`, `limit`, `offset` | same as list |
| `get` | required nonempty `account` and `messageID`; no query/limit/offset | `message`, `text`, `contentTrust` |

Account strings are exact matches, up to 1024 UTF-8 bytes. Message IDs are up to
4096 bytes and scoped by account (the same ID can exist in two accounts). List and
search reject `messageID`; list rejects `query`. Empty lists are successful. Missing
or deleted messages return `not_found`. All methods exclude local deleted tombstones;
other statuses, including spam, trash and archived, remain readable.

Each message contains `account`, `messageID`, `date` (Unix milliseconds), optional
`subject`, `fromName`, `fromEmail`, `snippet`, booleans `unread`/`starred`, and `status`.
No credential, account error, raw HTML, attachment or stored verification-code field
is returned. A later verification tool can derive its result from text under its own
policy without adding a write endpoint here.

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
