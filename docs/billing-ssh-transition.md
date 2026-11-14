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
                           └─ execs ONLY: python3 -B pigi_mcp.py --account adhielgona@gmail.com
                                └─ agent.sock (0600, getpeereid same-UID)
                                     └─ App LocalEngine.agentRead (read grant + scoped_accounts + audit)
```

Why the SSH identity lands on the owner account: `agent.sock` is 0600 and the
App enforces `getpeereid` same-UID, so no lower-privilege macOS user could reach
it. Confinement therefore happens at the forced command, not at the UID.

## Server-side objects (tr-mini-m4)

| Object | Content | Mode | Backup/rollback |
| --- | --- | --- | --- |
| `~/.ssh/pigi_forced_command.sh` | installed copy of `tools/pigi-mcp/pigi_forced_command.sh` from the **merged** checkout | 0700, owner `tr` | none today; rollback = delete file |
| `~/.ssh/authorized_keys` | single line below | 0600 | does not exist today — if it ever does, `cp -p` to `authorized_keys.bak-<ts>` first; rollback = remove only this line or restore backup |
| `~/Library/Application Support/pigi/forced-command.log` | sanitized event ledger created by the script | 0600 | rollback = delete file |

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
`SSH_ORIGINAL_COMMAND` comparison is a byte-exact match against
`<python> -B <script> --account <account>`.

## Trust conditions verified at rollout (before authorized_keys is installed)

- `sshd -T` (or `/etc/ssh/sshd_config*`) shows **no** `AcceptEnv` and
  `PermitUserEnvironment no` — the client cannot inject environment.
- `~/.ssh/environment` absent; `~/.ssh/rc` absent or individually vetted
  (`PermitUserRC`-reachable owner code).
- The script pins `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, unsets
  `BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT`, and
  re-execs the interpreter via `env -i` (only `HOME`, `PATH`, `PYTHONUTF8`), so
  no inherited variable can alter the pinned pipeline or its imports
  (`pigi_mcp.py` resolves `audit`/`transport` from its own directory).
- Authorization inputs are `readonly` literals; environment overrides were
  removed. The offline harness reproduced the old env-override path — that
  proved only the script honored env, not that sshd would pass client env.

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
| `~billing/.ssh/pigi_billing_ed25519` (+`.pub`) | dedicated ed25519 pair, generated on the box, never leaves it | 0600/0644 | rollback = delete pair |
| `~billing/.ssh/known_hosts` | `tr-mini-m4-pigi ssh-ed25519 <pubkey>` | 0600 | `cp -p` backup before edit if file exists; rollback restores backup or removes the added line |
| `~billing/.ssh/config` | stanza below | 0600 | same backup-then-append rule; rollback removes only this stanza |
| `/opt/pigi-mcp/remote_pigi_mcp.py` (or Billing-local path) | copy of the launcher | 0755 | rollback = delete file |
| Billing MCP host config | stdio server entry below | per Billing convention | backup config file first; rollback removes the added entry |

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
   approved to merge to `yicone/pigi` `main`. Nothing installs from the task
   worktree — deployment installs only from the merged checkout after
   verifying `git rev-parse HEAD` equals the accepted SHA and
   `git merge-base --is-ancestor <accepted> origin/main` succeeds.
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
   user or the macOS bot, not this run).
3. **Mini owner-side writes**: run the trust-condition checks above;
   `install -m 0700 tools/pigi-mcp/pigi_forced_command.sh ~/.ssh/` from the
   merged checkout; create `~/.ssh/authorized_keys` (0600) with the single
   pinned line (backup first if the file exists).
4. **Negative + handshake verification** (no mail data): a wrong command is
   refused, written to the ledger as `deny/mismatch`, and the stub path never
   runs; then MCP `initialize` + `tools/list` through Billing's connector
   returns exactly the four read tools (`list_accounts`, `search`,
   `list_messages`, `get_message`; `get_verification_code` is absent in
   `--account` mode).
5. **First real read** (`list_accounts` scoped call returning only the approved
   account, then a Cursor-support `search`/`get_message` example): separate
   numbered approval — this is the "real mailbox" boundary ACM-963 defers.

## Rollback (all steps reversible)

- Remove the `authorized_keys` line (today: delete the whole new file; if a
  backup was taken, restore it).
- `rm ~/.ssh/pigi_forced_command.sh` and the ledger if desired.
- Disable Remote Login (back to today's OFF state).
- Linux side: restore each backed-up file or remove the added stanza/entry;
  delete the keypair and launcher copy.
- No App restart, mail data, keychain, or repo state is touched at any point,
  so rollback leaves nothing behind on the mail side.

## Audit surfaces

- `~/Library/Application Support/pigi/forced-command.log`: one TSV line per
  SSH attempt — UTC timestamp, charset-validated peer, `allow`/`deny`, reason
  (`exact`/`mismatch`/`empty`/`pinned-unavailable`), request byte length, and a
  truncated SHA-256 of the request for correlation. The raw request is never
  written; the ledger itself is fail-closed (invalid directory/file type,
  ownership, mode, links, or any write failure = refuse). Retention is manual,
  matching the App's audit model.
- `~/Library/Application Support/pigi-mcp/audit.sqlite3`: adapter `tool_calls`
  ledger (tool name + outcome only).
- App `agent_actions` table + OSLog hook: engine-level durable audit.
- None of the three records mail bodies, credentials, or key material.
