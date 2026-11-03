# Proton helper protocol and packaging

Pigi launches `Contents/Helpers/pigi-proton-helper` using `ProtonHelperClient`.
One child owns one account session. No socket, listener, shell, CLI credential
flags, inherited environment, or session file is used. `ProtonSession` stores
UID, access/refresh tokens and the derived unlock secret in one application
Keychain item per canonical account email. Login passwords and OTPs are not
persisted. Keychain writes fail closed. Re-login replaces only the same account;
removing/replacing a session disables its subsequent Keychain writes.
There is no send operation or mailbox mutation API.

## Protocol v1

Private stdin/stdout pipes carry UTF-8 JSON objects, one LF-terminated object per
frame, at most 8,388,608 bytes excluding LF. One request at a time; nonzero
unsigned integer `id` values correlate responses. Swift increments IDs. JSON
strings escape embedded newlines. Stdout is protocol data, **never a log**;
credentials and message data on these private pipes must never be captured in
logs, comments, crash reports, analytics or test artifacts. Stderr is discarded
by Swift and library diagnostics are disabled in Go.

Every request has `version`, `id`, `method`, `params`. Every response has
`version:1`, the same `id`, and exactly one of `result` / `error`. Errors contain
only `{"code":"<fixed code>"}`, never API messages, URLs, identifiers or tokens.
The first request is `hello`. A mismatched major returns `unsupported_version`
without executing an operation. A compatible hello is required before other
methods; minor helper version is informational. Unknown fields in request and
method parameter objects are rejected. Unknown response error codes fail closed
in Swift. Invalid/malformed input returns `invalid_request` with id 0 and exits;
oversized input returns `frame_too_large` with id 0 and exits.

Synthetic handshake (contains no account data):

```json
{"version":1,"id":1,"method":"hello","params":{}}
{"version":1,"id":1,"result":{"protocol":1,"helper_version":"0.2.0","max_frame_bytes":8388608,"methods":["login","list","decrypt","logout","snapshot","metadata","labels","latest","events","session","resume"]}}
```

| Method | Params | Result |
| --- | --- | --- |
| `hello` | `{}` | Version, limit, supported methods |
| `login` | `username`, `password`; optional `mailbox_password`, `otp` strings | `{"authenticated":true}` |
| `list` | `page` ≥ 0, `limit` 1–100 | Array of `{id,subject,time,unread}` for inbox, newest first; time is Unix seconds |
| `decrypt` | `id` nonempty, ≤1024 bytes | `{body,mime_type,signature_status:"unverified"}`; UTF-8 plaintext decrypted locally with matching AddressID key |
| `snapshot` | `after` stable ID (empty initially), `limit` 1–100 | Array of message IDs from all folders; uses `AfterID`, not page offsets |
| `metadata` | `id` | `{id,subject,time,unread,sender_name,sender_email,labels,size}`; time is Unix seconds |
| `labels` | `{}` | Array of `{id,name,parent,type}`; user labels and folders |
| `latest` | `{}` | `{cursor}` sampled before starting a snapshot |
| `events` | `cursor` | `{cursor,more,reset,changes:[{id,deleted}]}`; fetches current metadata for partial flag events; refreshes address keys on key/address changes |
| `session` | `{}` | `{uid,access,refresh,salted,email}`; sensitive export for Keychain only; `salted` is base64 of the derived unlock secret |
| `resume` | Fields from `session` | `{authenticated:true}` after restoring session and unlocking address keys |
| `logout` | `{}` | `{"logged_out":true}` after remote revocation and local key clearing |

Login performs SRP, optional TOTP and key unlock. Failed post-auth login attempts
revoke the provisional session. A failed revoke keeps the client available only
for a retry of `logout`; list/decrypt are blocked because keys are cleared.
The legacy `login` method returns `human_verification_required` and
`second_factor_required` when interaction is required. The app uses `begin_login`
and `continue_login` to continue official CAPTCHA, TOTP and mailbox-password
challenges; verification URLs and results must pass the native challenge-binding
policy. Private keys never leave Go. Session tokens and the derived unlock secret
leave Go only through the private `session` response for Keychain storage. Plaintext signature authenticity is not asserted by this API.

| Code | Meaning / recovery |
| --- | --- |
| `network`, `timeout` | Connectivity/service failure or elapsed deadline; retry under caller control |
| `credentials` | SRP login, password, authorization or supplied OTP rejected |
| `human_verification_required` | Server requires manual CAPTCHA / rejects verification token |
| `second_factor_required` | TOTP missing or another interactive factor required |
| `key` | Mailbox key unlock or invalid plaintext encoding; check password/Keychain |
| `key_missing`, `key_format`, `key_decryption` | Missing key, unrecognized key/ciphertext format, or failed ciphertext decryption; distinct recovery hints |
| `api_version`, `proxy` | API rejects app version, or an API-formatted HTTP 407 proxy authentication response |
| `rate_limited` | Upstream 429; caller must back off |
| `not_authenticated`, `already_authenticated` | Invalid account-session state |
| `cleanup_failed` | Remote revocation unconfirmed; retry logout before abandoning child |
| `cursor_expired` | Reserved for a confirmed invalid cursor; never inferred from generic HTTP 400/422. Current SDK signals invalid incremental state with `RefreshMail` → `reset:true` |
| `not_found` | Message disappeared (record deletion); an events 404 alone does not authorize resnapshot |
| `upstream` | Other service error, without raw details |
| `invalid_request`, `invalid_params`, `unknown_method` | Caller/protocol error |
| `unsupported_version`, `handshake_required`, `frame_too_large` | Negotiation/framing failure |

Swift-only failures are `unavailable`, `transport`, `protocol_violation`.
Each Go request has a 60s network context; cleanup has a separate 10s bound.
Swift uses a 75s watchdog and a dedicated serial IO queue. Timeout/EOF/malformed
responses invalidate the session; calls never replay login automatically.
Before a session export, closing the pipe attempts bounded remote revocation.
After export/resume, EOF clears local keys without revoking the persisted session;
explicit `logout` still revokes it. Automatic token refresh is exported after every
operation, including failed operations where the helper remains reachable.
Swift permits 12s for EOF cleanup before terminating a remaining child. Remote
revocation cannot be guaranteed after a crash, forced termination or network
failure. Explicit successful `logout` is the confirmation boundary.

Buffers are cleared where mutable. Swift/Go strings, SDK internals and runtime
copies cannot guarantee complete in-memory zeroization; no such claim is made.

## Build, signing and notarization

Requires macOS, Xcode/Command Line Tools, XcodeGen and Go ≥1.26.1 (`GO_BIN` can
select a local toolchain). Dependency preparation checks a clean source checkout
of `go-proton-api` at `3f8fbebac58d144861efb8c41a04562389498125`.
`go-srp v0.0.7` and `gopenpgp/v2 v2.11.1-proton` are pinned in go.mod/go.sum;
all builds use `-mod=readonly`. Dependencies are never fetched by the running app.

```sh
bash tools/proton-spike/run.sh test
bash Tests/proton-helper-regression.sh
bash Tests/proton-sync-regression.sh
bash release.sh
build/Build/Products/Release/pigi.app/Contents/MacOS/pigi --proton-helper-selftest
```

Xcode builds pure-Go Darwin arm64 and amd64 slices, combines them with `lipo`,
embeds under `Contents/Helpers`, and signs the helper with the app's expanded
signing identity before the app envelope is signed. Local builds use ad-hoc
signatures. `release.sh` builds a universal app and verifies both app and helper
slices plus nested signatures, then executes an offline app-contained handshake
and logout. Intel execution requires an Intel Mac or working Rosetta; building
an x86_64 slice alone is not proof of execution on an Intel Mac.

For Developer ID distribution, configure `PIGI_SIGNING_IDENTITY` and
`PIGI_DEVELOPMENT_TEAM`. The certificate and private key must already be in the
signing Keychain. Optional `PIGI_NOTARY_PROFILE` names a preconfigured notarytool
Keychain profile; it is not a password or token. Never put Apple credentials in
environment variables or this repository. Only set that profile for an explicitly
authorized Apple notarization upload. The release script submits with `--wait`,
staples and validates the ticket, runs Gatekeeper assessment, then re-zips and
computes the final checksum. All failures stop packaging. No Git push or PR is
performed. See [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Ad-hoc signing provides local integrity checks; it is not Developer ID signing
or notarization and does not satisfy external distribution acceptance. Missing
Developer ID identity or notary profile is a release blocker, not a passing
notarization result.

## Read-only synchronization

The engine samples the latest event cursor before its first ID-paged snapshot.
Each metadata/body pair is retrieved using read-only endpoints, decrypted with the
message AddressID key, and saved to SQLite with milliseconds for the existing
mail date model. Decrypted PGP/MIME entities use the existing MIME parser to extract text/HTML.
HTML is compressed; searchable plaintext and snippets are local.
System IDs map to INBOX/STARRED/TRASH/SPAM/SENT/DRAFT/ARCHIVE/ALL; custom labels use
`proton:<id>` and an account-scoped catalog preserving name, parent and type.
The account's folder/label picker reads this catalog. Opening mail and all write
actions preserve Proton read/star/folder state, enforced again in the engine.

A page checkpoint advances only after every body is saved. The event cursor
advances only after every change/deletion is applied; retries safely replay the
same cursor. Snapshot completion tombstones local messages absent remotely.
Refresh events start a new snapshot before reconciling stale local messages.
Failures save only fixed safe error descriptions; no raw upstream diagnostics,
credentials, key material or message bodies may enter logs or artifacts.

`proton-sync-regression.sh` uses an in-memory SQLite database and synthetic
sessions, never the user's database or Keychain. Helper Go tests use a loopback
HTTP fixture and generated OpenPGP keys. These verify failure/replay and local
mapping, but do not establish a real Proton account login or CAPTCHA flow.

## Security audit

See [Proton security audit](proton-security-audit.md) for repeatable failure tests,
cache privacy/deletion limits, proxy support boundaries, runtime license inventory
and the bounded telemetry conclusion. Dependency notices and inventory are embedded
in the app resources during builds.
