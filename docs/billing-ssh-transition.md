# Billing transitional read access over restricted SSH (ACM-963)

Temporary bridge until the long-term token-auth design (ACM-962) lands. It gives
the Grok Bot **Billing** read-only access to the approved account
`adhielgona@gmail.com` through the running pigi App's `agent.sock`. Nothing here
grants unrestricted shell access to the mini: the only deliverable to the SSH
layer is one pinned forced command.

Every write below is a separately approved rollout step. This document is the
plan and the inventory of objects; ACM-963 executes none of it without the
corresponding numbered approval.

## Path

```
Billing MCP host (shared Linux box)
  └─ stdio: remote_pigi_mcp.py          (launcher, repo tools/pigi-mcp/)
       └─ ssh -T (BatchMode, StrictHostKeyChecking, no forwarding)
            └─ tr-mini-m4 sshd, user tr
                 └─ authorized_keys: from=<billing-src>,restrict,command="…"
                      └─ pigi_forced_command.sh  (never executes the client command)
                           └─ wire contract: <python> -B <script> --account <acct>
                           └─ execs ONLY: python3 -B -E -S -X utf8 pigi_mcp.py
                                          --account adhielgona@gmail.com
                                └─ agent.sock (0600, getpeereid same-UID)
                                     └─ App LocalEngine.agentRead (read grant + scoped_accounts + audit)
```

Why the SSH identity lands on the owner account: `agent.sock` is 0600 and the
App enforces `getpeereid` same-UID, so no lower-privilege macOS user could reach
it. Confinement therefore happens at the forced command, not at the UID.

## Server-side objects (tr-mini-m4)

Before any write to an object below, record its **prior existence, type,
owner, mode, and content hash** (or full content where safe) plus the relevant
service state. If an object exists unexpectedly — anything not predicted in
this table — STOP and report; never overwrite a pre-existing object and then
delete it on rollback. Rollback always means *restore the recorded prior
state*: bring back a backed-up file byte-for-byte, or leave absent only what
was absent before.

| Object | Content | Mode | Backup/rollback |
| --- | --- | --- | --- |
| `~/.ssh/pigi_forced_command.sh` | installed copy of `tools/pigi-mcp/pigi_forced_command.sh` from the **merged** checkout | 0700, owner `tr` | expected absent today (verified) — if present at rollout, STOP; rollback = delete only if it was absent before, else restore backup |
| `~/.ssh/authorized_keys` | single line below | 0600 | expected absent today (verified) — if present at rollout, `cp -p` to `authorized_keys.bak-<ts>` and append; rollback restores the backup (or deletes the file only if it was absent before) — never blindly `rm` |
| `~/Library`, `~/Library/Application Support` | intermediate parents of every path below; exist on any macOS HOME — if either is absent the adapter/script creates it (0700) | 0700 | pre-existing (record existence/mode only); if absent and auto-created, log that fact — deletion only if created by this rollout |
| `~/Library/Application Support/pigi/` | ledger parent; exists today (App data dir), auto-created 0700 by the script only if absent | 0700 | exists today — record mode/owner; if absent at rollout the script creates it: log that; rollback deletes it only if it was created by this rollout |
| `~/Library/Application Support/pigi/forced-command.log` | sanitized event ledger created by the script | 0600 | **audit object — never overwritten or blindly deleted.** Expected absent today — if present, STOP and inventory it; if created by this rollout, rollback *retains* it by default as an audit record — deleting it is a decision the rollback approval must name explicitly |
| `~/Library/Application Support/pigi-mcp/` | adapter audit parent, auto-created 0700 on first adapter start — before any tool call, on EOF | 0700 | expected absent today — if present, STOP and inventory it; if created by this rollout it is retained with the DB it contains |
| `~/Library/Application Support/pigi-mcp/audit.sqlite3` (+ transient `-journal`) | adapter `tool_calls` ledger, auto-created 0600 at `Audit()` init on every adapter start | 0600 | **audit object — never overwritten or blindly deleted.** If present at rollout, STOP and inventory (existence/type/owner/mode/hash). If created by this rollout, rollback *retains* it by default as an audit record — deleting it is itself a decision the rollback approval must name explicitly. The `-journal` file is transient (created on write, removed on commit) and inherits the same policy — a crash-residue journal found later is treated as an audit object, not auto-deleted; its crash-recovery lifecycle is **unverified** offline |

`authorized_keys` line (exact):

```
from="<billing-src>",restrict,command="/Users/tr/.ssh/pigi_forced_command.sh" ssh-ed25519 AAAA...<billing-pubkey>
```

- The installed path is deliberately **space-free** (`~/.ssh` already exists,
  0700), so no inner quoting is needed. If a spaced path is ever used, the
  authorized_keys parser and `sh -c` are two layers: the stored value must be
  `command="\"/path with space/script\""`. The self-test proves both forms
  against a real `Application Support` path.
- `restrict` disables agent/X11/port forwarding, PTY and user-rc for this key;
  `from=` rejects other sources.
- `from=` is **required by default**: `<billing-src>` is Billing's confirmed
  stable source address (Tailscale IP preferred). If no stable source exists,
  the rollout STOPS — omitting `from=` is allowed only when the user records
  that accepted risk in the numbered approval.

The pinned pipeline uses the deployed checkout
`~/Workspace/pigi/tools/pigi-mcp/pigi_mcp.py` and interpreter
`/Users/tr/.pyenv/versions/3.11.13/bin/python3` — the adapter requires Python
3.10+; the system `/usr/bin/python3` is 3.9.6 and is NOT used. The interpreter
path must be a real executable, not a pyenv shim. If the checkout moves, update
the installed script's `PIGI_MCP_SCRIPT` literal and redeploy it; the
`SSH_ORIGINAL_COMMAND` comparison is a byte-exact match against the wire
contract `<python> -B <script> --account <account>` — the remote launcher sends
exactly that string, and the forced command adds its own `-E -S -X utf8`
hardening flags when it re-execs the interpreter.

## Trust conditions verified at rollout (before authorized_keys is installed)

- `sshd -T` (or `/etc/ssh/sshd_config*`) shows **no** `AcceptEnv` and
  `PermitUserEnvironment no` — the client cannot inject environment.
- `~/.ssh/environment` absent; `~/.ssh/rc` absent or individually vetted
  (`PermitUserRC`-reachable owner code).
- The script pins `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, unsets
  `BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT`,
  and re-execs the interpreter via `env -i` carrying only `HOME` (the pinned
  `PIGI_FC_HOME` literal, never the caller's) and `PATH`. The interpreter then
  runs `-B -E -S -X utf8`: `-E` ignores any `PYTHON*` variable that survives,
  `-B` stops `.pyc` writes, and `-S` skips the `site` module entirely — no
  global or per-user site-packages, no `.pth` file execution, no
  `sitecustomize`/`usercustomize`. `PYTHONSTARTUP` only affects interactive
  sessions and is moot here. With `-S`, `sys.path` is the script's own
  directory plus the stdlib, which is exactly what `pigi_mcp.py` needs
  (`audit`/`transport` are siblings of the script). A hostile `.pth` planted
  under the *passed* HOME's user-site is proven inert by the offline probe
  test — but the passed HOME is still a trust surface for the script's own
  future use, which is why `PIGI_FC_HOME` is a literal and the ledger path is
  a literal rather than `$HOME`-derived.
- Authorization inputs are `readonly` literals; environment overrides were
  removed. The offline harness reproduced the old env-override path — that
  proved only the script honored env, not that sshd would pass client env.
  Whether sshd passes client-supplied environment at all is an sshd-side
  property verified at rollout via the checks above — offline tests do not
  prove the online injection path.
- The script directory, interpreter, stdlib, the pinned HOME, and the deployed
  checkout must all be owner-writable only; an attacker who can write
  `pigi_mcp.py`, its sibling modules, the interpreter, or a stdlib file wins
  regardless of flags. These paths are inventoried and their modes recorded
  during rollout.
- Rollout dependency: `/usr/bin/perl` (stock macOS) must exist and be the
  unmodified system tool — the forced command uses it for `fstat(2)` on the
  pinned descriptor, and refuses (fail-closed) if it is absent. On the mini
  verify `ls -l /usr/bin/perl` and `perl -v` once during trust-condition
  checks; other deployment hosts must confirm equivalent availability.

## Host key pinning (one canonical identifier)

`tr-mini-m4-pigi` is the single name used by **all three** of: the ssh `--host`
argument, the ssh config `Host`/`HostKeyAlias`, and the `known_hosts` key.

- Mini Ed25519 host key fingerprint (out-of-band value, confirmed on the mini
  from `/etc/ssh/ssh_host_ed25519_key.pub`):
  `SHA256:GLeXZX3ZMQbxTlTr/xNxH89co1Rj+NBInJBnuMxyaLc`
- At rollout the operator obtains the full public host key through a trusted
  channel (user or this issue, never the first SSH connection), writes it to
  `~billing/.ssh/known_hosts` keyed `tr-mini-m4-pigi`, then verifies with
  `ssh-keygen -lf ~billing/.ssh/known_hosts` that the pinned fingerprint equals
  the out-of-band value.
- `StrictHostKeyChecking=yes` + `BatchMode=yes` in the launcher means a wrong
  host key FAILS the connection; there is no TOFU prompt to accept.

## Linux-side objects (shared box; executor named in the approval)

| Object | Content | Mode | Backup/rollback |
| --- | --- | --- | --- |
| `~billing/.ssh/pigi_billing_ed25519` (+`.pub`) | dedicated ed25519 pair, generated on the box, never leaves it | 0600/0644 | same-name pair must NOT exist before generation — if it does, STOP (do not clobber someone's key); rollback = delete only the newly generated pair |
| `~billing/.ssh/known_hosts` | `tr-mini-m4-pigi ssh-ed25519 <pubkey>` | 0600 | `cp -p` backup before edit if file exists; rollback restores the backup (or deletes only if the file was absent) |
| `~billing/.ssh/config` | stanza below | 0600 | same backup-then-append rule; rollback restores backup or removes only this stanza; an existing `Host tr-mini-m4-pigi` stanza = STOP |
| `/opt/pigi-mcp/remote_pigi_mcp.py` (or Billing-local path) | copy of the launcher | 0755 | expected absent — if present, STOP and identify its origin; rollback = delete only if installed by this rollout |
| Billing MCP host config | stdio server entry `pigi-mail-read` below | per Billing convention | backup config file first; an existing `pigi-mail-read` key (or any `pigi-*` key) in the config = STOP and identify it — never silently replace; rollback removes only the entry this rollout added, byte-restoring the backup |

Isolation requirements on the shared box:

- Billing must run under a **dedicated UID**; the private key lives in that
  user's own `~/.ssh` (0700) and is unreadable by other bots. If Billing shares
  a UID with other Grok Bots, that is an isolation gap — STOP and report.
- Passphrase: recommended empty passphrase **plus** forced command + `from=` +
  host pinning for this transitional phase; alternatively a passphrase kept in
  Billing's secret store. Decision recorded at approval — unresolved = stop.
- `IdentitiesOnly yes` so no other key in the agent is offered.

`~billing/.ssh/config` stanza:

```
Host tr-mini-m4-pigi
    HostName 100.104.164.12        # mini Tailscale IP; use LAN IP if on-link
    User tr
    IdentityFile ~/.ssh/pigi_billing_ed25519
    IdentitiesOnly yes
    HostKeyAlias tr-mini-m4-pigi
```

Billing MCP host stdio entry (exact path per Billing conventions):

```json
"pigi-mail-read": {
  "command": "python3",
  "args": ["/opt/pigi-mcp/remote_pigi_mcp.py",
           "--host", "tr-mini-m4-pigi",
           "--remote-script", "/Users/tr/Workspace/pigi/tools/pigi-mcp/pigi_mcp.py",
           "--account", "adhielgona@gmail.com",
           "--remote-python", "/Users/tr/.pyenv/versions/3.11.13/bin/python3"]
}
```

The `--account`, `--remote-script`, and `--remote-python` args must match the
forced command's pinned string verbatim, or the request is logged and refused.

## Gates and rollout order (each needs its own numbered approval)

0. **Code gate**: this change set passes independent offline re-review, then
   the author is separately approved to push/PR and DevOps is separately
   approved to merge to `yicone/pigi` `main`. **The deployment object is the
   merged `main` HEAD, never the feature candidate** — a normal merge commit
   gives `main` a new SHA, so `git rev-parse HEAD` will NOT equal the accepted
   candidate and must not be required to. Verification before installing:
   - `git merge-base --is-ancestor <accepted> origin/main` — the reviewed
     candidate is contained in the merge; and
   - `git diff --exit-code <accepted> origin/main -- tools/pigi-mcp
     docs/billing-ssh-transition.md` — the deployed tree for every path this
     change touches is identical to the reviewed tree.
   Ancestor relation alone is not the safety claim: if the merged tree of the
   affected paths differs from the reviewed tree in any way, STOP — the merge
   changed what was reviewed and a new independent re-review is required
   before deploying. (Fast-forward acceptance is also fine: there `main` HEAD
   *is* the reviewed SHA.)
   **Preconditions that must be confirmed before any deploy approval**:
   Billing dedicated UID (evidence), key passphrase decision, Billing stable
   source address for `from=`. Any of them unconfirmed → STOP; do not omit
   `from=` by default. The user names the Linux-side executor — nothing is
   auto-dispatched to Steward.
1. **Linux side**: generate keypair, write `known_hosts` (with out-of-band
   pubkey comparison above), ssh config stanza, copy `remote_pigi_mcp.py`,
   register the Billing MCP connector — each file backed up first per the
   table. Produces the public key step 3 needs. No mail data touched.
2. **Remote Login on the mini**: user enables it in System Settings → Sharing →
   Remote Login, restricted to user `tr` (system-layer step; belongs to the
   user or the macOS bot, not this run). First RECORD the prior Remote Login
   state (`sudo systemsetup -getremotelogin` or the Sharing pane) in the
   rollout log — rollback restores that recorded state, not a blind "off".
3. **Mini owner-side writes**: run the trust-condition checks above; record
   each object's prior existence/type/owner/mode/hash per the inventory rule;
   `install -m 0700 tools/pigi-mcp/pigi_forced_command.sh ~/.ssh/` from the
   merged checkout; create `~/.ssh/authorized_keys` (0600) with the single
   pinned line (backup first if the file exists; STOP if an existing file
   already contains a `pigi_forced_command` line).
4. **Negative + handshake verification** (no mail data): a wrong command is
   refused, written to the ledger as `deny/mismatch`, and the stub path never
   runs; then MCP `initialize` + `tools/list` through Billing's connector
   returns exactly the four read tools (`list_accounts`, `search`,
   `list_messages`, `get_message`; `get_verification_code` is absent in
   `--account` mode).
5. **First real read** (`list_accounts` scoped call returning only the approved
   account, then a Cursor-support `search`/`get_message` example): separate
   numbered approval — this is the "real mailbox" boundary ACM-963 defers.

## Rollback (restore recorded prior state — never "delete everything")

Rollback replays the pre-write inventory in reverse and restores what was
recorded; nothing pre-existing is destroyed:

- `authorized_keys`: restore the `cp -p` backup byte-for-byte; if the file did
  not exist before this rollout, delete it. Never `rm` a file that existed.
- `pigi_forced_command.sh` and ledger: delete only if the inventory shows they
  were absent before this rollout; otherwise restore the recorded backup.
- Remote Login: return to the recorded prior state (today's verified state is
  OFF — but the rollout log's recorded value is authoritative, not this doc's
  snapshot; a system admin may have enabled it for other reasons in between,
  and blindly disabling it would break that).
- Forced-command ledger and adapter audit objects (`pigi/` and `pigi-mcp/`
  dirs, `forced-command.log`, `audit.sqlite3`, transient `-journal`): if
  created by this rollout they are audit records — RETAIN by default;
  deletion requires an explicit named decision in the rollback approval.
  Pre-existing ones are never touched.
- Linux side: restore each backed-up file or remove only the added
  stanza/entry; delete the keypair and launcher copy only if they did not
  exist before.
- No App restart, mail data, keychain, or repo state is touched at any point.
  Note rollback does **not** leave "nothing behind" in the strict sense: the
  forced-command ledger and adapter audit DB are audit trails this rollout
  legitimately creates — they are retained unless the rollback approval says
  otherwise. Everything *pre-existing* is left untouched.

## Audit surfaces

- `~/Library/Application Support/pigi/forced-command.log`: one TSV line per
  SSH attempt — UTC timestamp, charset-validated peer, `allow`/`deny`, reason
  (`exact`/`mismatch`/`empty`/`pinned-unavailable`/`detached`), request byte
  length, and a truncated SHA-256 of the request for correlation. The raw
  request is never written; the ledger itself is fail-closed (invalid
  directory/file type, ownership, mode, links, or any write failure =
  refuse). Append binding: full path validation (ancestors, leaf dir, file
  policy) runs before *and* after the append descriptor is opened; the
  descriptor's real fstat dev/inode/uid/mode/nlink must match the validated
  object at every gate; the emit statement itself re-checks the descriptor
  in the same command so a change staged before it refuses *before* any byte
  is written; and a full gate re-runs immediately before exec — staged
  same-UID changes at the boundaries the offline probes covered refuse
  (`deny/detached`) without appending to a wrong object. Honest residuals:
  (a) the instruction-scale window between the last fstat inside the emit
  statement and the write syscall, and (b) between the final gate and
  `exec` — neither can redirect a record to a wrong object, only
  theoretically detach the canonical path for a nanosecond-scale interval.
  All demonstrated windows are same-UID synthetic probes, not remote or
  cross-UID attacks; cross-UID is unverified. The fstat checks require
  `/usr/bin/perl` (stock macOS) — listed as a rollout dependency below.
  Retention is manual, matching the App's audit model.
- `~/Library/Application Support/pigi-mcp/audit.sqlite3`: adapter `tool_calls`
  ledger (tool name + outcome only).
- App `agent_actions` table + OSLog hook: engine-level durable audit.
- None of the three records mail bodies, credentials, or key material.
