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
the second. There is no bearer token, password or credential exchange. Any process
running as the same user can call the socket; the engine additionally applies the
account grants below. These grants constrain the service, not direct database/file
access by compromised same-user code or root, and do not provide per-process consent.
Consumers must not expose this socket through a network
proxy or share its results with another user without separate authorization.

### Account capabilities (ACM-751)

Settings → Agent owns independent `read`, `draft`, and `organize` grants per account,
defaulting to read + draft. Grants persist in `agent_permissions`; existing and newly
added accounts use these defaults. Removing an account also removes its grants.
Sending is a fixed false constant with no setting. Draft/organize are reserved grants:
this read-only protocol does not implement those operations even when granted.

`LocalEngine.agentRead` checks read before scoped access; unknown or revoked accounts
return `permission_denied` without looking up messages. Unscoped accounts/list/search/
codes queries filter unreadable accounts in SQL before sorting and pagination, so
revoked accounts cannot leak through discovery, snippets, FTS, codes or page offsets.
Revocation takes effect for subsequent calls on the running service. Draft/organize
do not imply read. The method whitelist never dispatches account deletion, credential
read/export, OAuth client changes, permission changes, audit access, or sending.

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
| `permission_denied` | scoped account is unknown or read is revoked |
| `audit_unavailable` | durable action audit could not begin/finish; no mail returned |
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

The engine now persists `agent_actions(ts, tool, account, target, args_hash, result)`
on its existing SQLite connection, also for direct socket clients that bypass MCP.
Settings → Agent shows paginated records. Intent is written before dispatch;
completion records `allowed` or a fixed protocol error code before data is returned.
A crash or failed completion can leave `started` (outcome unknown). Malformed/oversized
frames, peer-auth errors and read timeouts are recorded without retaining input bytes.
`allowed` describes engine execution, not proof that a client received the response.

Account, target and canonical arguments use domain-separated HMAC-SHA256 digests with
a random per-database key in `agent_audit_key`. This avoids plaintext identifiers and
unsalted hashes of guessable queries/codes; request IDs, mail content, arbitrary method
names, credentials and raw errors are never stored in the ledger. The key and ledger
share the mail database's 0600 protection; neither is tamper-proof against the same
user. The existing OSLog callback and MCP `tool_calls` remain transport diagnostics,
including tools rejected by MCP before any socket call, rather than a second App
action ledger. The App does not open the adapter's separate database. Retention is
manual; no pruning is performed.

## Implementation and validation plan

1. Define reusable Codable v1 wire types and actor-isolated read operations.
2. Add permission/UID-checked bounded socket transport and App lifecycle ownership.
3. Exercise a real temporary socket against an in-memory engine with synthetic mail:
   methods, account scoping, paging, literal search, errors, unsafe paths, stale recovery,
   bounds, concurrent reads, timeouts, disconnects and restart cleanup.
4. Run `swift test`, relevant existing regression scripts and `tools/build-debug.sh`.
   Do not launch/restart the user's App or use real accounts. Deliver on a fork branch
   and PR; merging/deployment remains separately authorized.

## Synthetic settings interaction fixture (ACM-751 / ACM-954 follow-up)

On a logged-in macOS desktop with the repository's existing Xcode tools, run:

```sh
bash Tests/agent-settings-ui.sh --test
bash Tests/agent-settings-ui.sh --manual
```

No dependencies are installed. This compiles a standalone, unsigned executable in a
random `/tmp/pigi-agent-settings.*` directory. It links the **production**
`AgentSettingsPage`, `PageHeader`, LocalEngine and Store; it does NOT compile
`PigiApp.swift`, AppDelegate, MailCache, or the production Keychain implementation.
The page receives an explicit fixture engine; the normal App still defaults to shared.
The test's keychain replacement immediately fails on any accidental access. Sync is
never started. All accounts end in `.invalid`; SQLite, preferences and HOME are disposable.

Compilation uses the existing write-isolation wrapper. Before any GUI is created,
the executable proves that its runtime profile denies the entire canonical passwd
home (including real pigi data, Containers and keychains), tests actual read/write
denial on a **synthetic** canary (`EPERM`), tests IP network denial (`EPERM`), and checks
AppSupport isolation. No real DB or keychain is opened as a probe. GUI modes deny all
network access and securityd lookup. These checks fail closed; there is no unsandboxed
fallback. `sandbox-exec` is required. Nothing is installed, signed, launched as the
real App, or written into the user's normal app data/configuration.

Automatic mode activates the actual native accessibility press actions of the SwiftUI
controls, not their Binding closures or backend save methods. Fixture toolbar buttons
use their native `NSButton.performClick` actions. It reads control values/messages
and verifies temporary DB persistence after the view AND engine/connection are destroyed
and recreated. Accessibility is enabled only inside this process via AppKit's legacy
accessibility attribute API (deprecated SDK warnings are expected); no system AX/TCC
permission or global preference is changed. The log distinguishes each `PRESS` from
the resulting `PASS`. Unsupported control access or missing UI changes fails the run;
a compile or backend-only success cannot pass these checks.

Manual mode shows a window titled **Pigi Agent Settings — SYNTHETIC ONLY**. Its toolbar
belongs to the test host, not the product. Repeat these operations with the mouse:

1. Toggle read/draft off and organize on. Click **关闭重开**; verify all three values
   survive (a new engine reads the same temporary file). Sending has no toggle.
2. Scroll to audit pagination. The 205 synthetic records span three pages: click
   next/previous and check boundary buttons. **追加审计** adds a record; **刷新** in
   the production page reveals it. Toolbar actions alone do not refresh that page.
3. Click **保存失败**, then a permission toggle: check the error message and retained
   prior value. Click **恢复** and retry the toggle: error clears and value saves.
4. Click **加载失败**, then page **刷新**: check the load error. Click **恢复**, then
   **刷新**: the existing audit records return and the error clears.
5. Click **空数据**: check **暂无邮箱**, **暂无记录** and disabled pagination. Click
   **合成数据** to restore the normal state. Close the window to exit and delete the
   temporary directory. Automatic mode exits and cleans up without user interaction.

This is repeatable author/self-test infrastructure, not independent acceptance or
proof of the production App's packaging, launch, real-mail integration or historical logs.

### Cross-UID probe: additional authorization required

The following smoke test needs no additional identity and **does not prove cross-UID rejection**:

```sh
bash Tests/agent-settings-ui.sh --peer-smoke
```

For a future explicitly authorized cross-UID test, run the following as the ordinary
owner in terminal A; it opens only an empty synthetic engine, never a GUI or real App:

```sh
bash Tests/agent-settings-ui.sh --peer-server
```

It prints `SYNTHETIC_SOCKET=...` and waits at most 45 seconds. Peer modes allow AF_UNIX
for that fixture but still prove IP networking is denied and use the same home/keychain
guards. In terminal B, **only after the user approves this single privileged probe**:

```sh
sudo /usr/bin/python3 -B Tests/agent-peer-probe.py '<printed SYNTHETIC_SOCKET path>'
```

Minimum extra authorization: execute this inspected standard-library Python probe as
the already-existing root identity, while the server remains the ordinary owner. The
probe only connects to a private `/private/tmp/pigi-agent-settings.*/peer/agent.sock`,
asserts different UIDs and mode 0600, and requires `unauthorized` without a result.
Root can traverse the unchanged private directory, so this tests the real `getpeereid`
branch rather than only filesystem refusal. The server verifies the synthetic audit
row is `unauthorized`, exits and cleans up. No user is created, no chmod/ownership is
changed, and neither script invokes sudo automatically. An unprivileged existing second
user would normally be blocked by directory/socket permissions before reaching the UID
guard; that is a different test and cannot replace this evidence. If privilege is not
approved, or the endpoint cannot be reached, keep cross-UID verification **unverified**.

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
