# Proton helper protocol and packaging

Pigi launches `Contents/Helpers/pigi-proton-helper` using `ProtonHelperClient`.
One child owns one ephemeral account session. No socket, listener, shell, CLI
credential flags, inherited environment, or persistent session file is used.
The app keeps credentials in its existing Keychain domain; this transport does
not create or read Keychain items. Credential collection, CAPTCHA/TOTP UI,
session persistence/refresh, multi-account UI and synchronization are subsequent
integration work. There is no send operation.

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
{"version":1,"id":1,"result":{"protocol":1,"helper_version":"0.1.0","max_frame_bytes":8388608,"methods":["login","list","decrypt","logout"]}}
```

| Method | Params | Result |
| --- | --- | --- |
| `hello` | `{}` | Version, limit, supported methods |
| `login` | `username`, `password`; optional `mailbox_password`, `otp` strings | `{"authenticated":true}` |
| `list` | `page` ≥ 0, `limit` 1–100 | Array of `{id,subject,time,unread}` for inbox, newest first; time is Unix seconds |
| `decrypt` | `id` nonempty, ≤1024 bytes | `{body,mime_type}`; UTF-8 plaintext decrypted locally with matching AddressID key |
| `logout` | `{}` | `{"logged_out":true}` after remote revocation and local key clearing |

Login performs SRP, optional TOTP and key unlock. Failed post-auth login attempts
revoke the provisional session. A failed revoke keeps the client available only
for a retry of `logout`; list/decrypt are blocked because keys are cleared.
`human_verification_required` and `second_factor_required` are explicit terminal
login outcomes in v1. CAPTCHA continuation is deliberately not implemented here;
the ACM-769 native interactive spike remains a separate diagnostic. Do not claim
the new helper can yet complete a CAPTCHA login. Private keys and refresh tokens
never leave Go. Plaintext signature authenticity is not asserted by this API.

| Code | Meaning / recovery |
| --- | --- |
| `network`, `timeout` | Connectivity/service failure or elapsed deadline; retry under caller control |
| `credentials` | SRP login, password, authorization or supplied OTP rejected |
| `human_verification_required` | Server requires manual CAPTCHA / rejects verification token |
| `second_factor_required` | TOTP missing or another interactive factor required |
| `key` | Missing mailbox/address key, unlock/decryption failed, invalid body encoding |
| `rate_limited` | Upstream 429; caller must back off |
| `not_authenticated`, `already_authenticated` | Invalid account-session state |
| `cleanup_failed` | Remote revocation unconfirmed; retry logout before abandoning child |
| `upstream` | Other service error, without raw details |
| `invalid_request`, `invalid_params`, `unknown_method` | Caller/protocol error |
| `unsupported_version`, `handshake_required`, `frame_too_large` | Negotiation/framing failure |

Swift-only failures are `unavailable`, `transport`, `protocol_violation`.
Each Go request has a 60s network context; cleanup has a separate 10s bound.
Swift uses a 75s watchdog and a dedicated serial IO queue. Timeout/EOF/malformed
responses invalidate the session; calls never replay login automatically.
Closing the input pipe attempts bounded remote revocation and clears keys.
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
