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
                 └─ authorized_keys: restrict,command="pigi_forced_command.sh"
                      └─ execs ONLY: python3 -B pigi_mcp.py --account adhielgona@gmail.com
                           └─ agent.sock (0600, getpeereid same-UID)
                                └─ App LocalEngine.agentRead (read grant + scoped_accounts + audit)
```

Why the SSH identity lands on the owner account: `agent.sock` is 0600 and the
App enforces `getpeereid` same-UID, so no lower-privilege macOS user could reach
it. Confinement therefore happens at the forced command, not at the UID.

## Server-side objects (tr-mini-m4)

| Object | Content | Mode | State before approval |
| --- | --- | --- | --- |
| `~/Library/Application Support/pigi/pigi_forced_command.sh` | installed copy of `tools/pigi-mcp/pigi_forced_command.sh` | 0700, owner `tr` | absent |
| `~/.ssh/authorized_keys` | single line, see below | 0600 | absent (no file exists today) |
| `~/Library/Application Support/pigi/forced-command.log` | attempt ledger created by the script | 0600 | absent |
| Remote Login | currently OFF (nothing listens on :22) | — | unchanged |

`authorized_keys` line (exact; `<billing-src>` is the Billing box source
address — Tailscale IP preferred, to be confirmed at rollout):

```
from="<billing-src>",restrict,command="/Users/tr/Library/Application Support/pigi/pigi_forced_command.sh" ssh-ed25519 AAAA...<billing-pubkey>
```

`restrict` disables agent/X11/port forwarding, PTY and user-rc for this key;
`from=` rejects other sources. If no stable source address exists, drop `from=`
and record the accepted risk in the approval reply — the forced command still
confines the key.

The pinned pipeline uses the deployed checkout
`~/Workspace/pigi/tools/pigi-mcp/pigi_mcp.py` (currently main
`92a6849950cf0e390cab0d3d9d01de7dc5c84005`, same SHA as the running Debug App)
and interpreter `/Users/tr/.pyenv/versions/3.11.13/bin/python3` — the adapter
requires Python 3.10+; the system `/usr/bin/python3` is 3.9.6 and is NOT used.
If the worktree is later moved or rebuilt elsewhere, update both the installed
script's `PIGI_MCP_SCRIPT` default and the expected string, or redeploy the
installed copy.

Host key verification: the Linux side pins the mini's Ed25519 host key before
first connect (`StrictHostKeyChecking=yes` is already hardcoded in
`remote_pigi_mcp.py`). Fingerprint for out-of-band confirmation:

```
/etc/ssh/ssh_host_ed25519_key.pub  SHA256:GLeXZX3ZMQbxTlTr/xNxH89co1Rj+NBInJBnuMxyaLc
```

## Linux-side objects (shared box, executed by Steward / Multica ops)

| Object | Content | Mode |
| --- | --- | --- |
| `~billing/.ssh/pigi_billing_ed25519` (+`.pub`) | dedicated ed25519 keypair, generated on the box, never leaves it | 0600/0644 |
| `~billing/.ssh/known_hosts` | `tr-mini-m4 ssh-ed25519 <pubkey>` (mini host key) | 0600 |
| `~billing/.ssh/config` | stanza below | 0600 |
| `/opt/pigi-mcp/remote_pigi_mcp.py` (or Billing-local path) | copy of the launcher | 0755 |
| Billing MCP host config | stdio server entry below | per Billing convention |

Isolation requirements on the shared box:

- The private key lives in the `billing` user's own `~/.ssh` (0700), unreadable
  by other bots. If Billing shares a UID with other Grok Bots, that is an
  isolation gap — report it instead of proceeding.
- Passphrase: recommended empty passphrase **plus** forced command + `from=` +
  host pinning for this transitional phase; alternatively a passphrase kept in
  Billing's secret store. Decision recorded at approval.
- `IdentitiesOnly yes` so no other key in the agent is offered.

`~billing/.ssh/config` stanza:

```
Host tr-mini-m4-pigi
    HostName 100.104.164.12        # mini Tailscale IP; use LAN IP if on-link
    User tr
    IdentityFile ~/.ssh/pigi_billing_ed25519
    IdentitiesOnly yes
```

Billing MCP host stdio entry (exact path/host alias per Billing conventions):

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

## Rollout order and approval points

1. **Linux keypair + ssh config + known_hosts + launcher copy + MCP connector
   entry** (Steward/Multica ops, after confirming Billing's UID is dedicated).
   Produces the public key that step 3 needs. No mail data touched.
2. **Remote Login on the mini**: user enables it in System Settings → General →
   Sharing → Remote Login, restricted to user `tr` (system-layer step; belongs
   to the user or the macOS bot, not this run).
3. **Mini authorized_keys + installed forced command**:
   `install -m 0700 tools/pigi-mcp/pigi_forced_command.sh "$HOME/Library/Application Support/pigi/"`,
   then create `~/.ssh/authorized_keys` (0600) with the single pinned line.
4. **Negative + handshake verification** (no mail data):
   `ssh tr-mini-m4-pigi 'echo hi'` → refused with "command not permitted" and a
   ledger line; then MCP `initialize` + `tools/list` through Billing's
   connector → exactly the four read tools
   (`list_accounts`, `search`, `list_messages`, `get_message`;
   `get_verification_code` is absent in `--account` mode).
5. **First real read** (`list_accounts` scoped call returning only the approved
   account, then a Cursor-support `search`/`get_message` example): separate
   numbered approval — this is the "real mailbox" boundary ACM-963 defers.

## Rollback (all steps reversible)

- Remove the `authorized_keys` line (today: delete the whole new file).
- `rm "$HOME/Library/Application Support/pigi/pigi_forced_command.sh"` and the
  ledger if desired.
- Disable Remote Login (back to today's OFF state).
- Linux side: delete the connector entry, launcher copy, ssh stanza, keypair,
  known_hosts line.
- No App restart, mail data, keychain, or repo state is touched at any point,
  so rollback leaves nothing behind on the mail side.

## Audit surfaces

- `~/Library/Application Support/pigi/forced-command.log`: every SSH attempt
  (allowed or refused) with timestamp, peer, requested command. Append-only;
  retention is manual, matching the App's audit model.
- `~/Library/Application Support/pigi-mcp/audit.sqlite3`: adapter `tool_calls`
  ledger (tool name + outcome only).
- App `agent_actions` table + OSLog hook: engine-level durable audit.
- None of the three records mail bodies, credentials, or key material.
