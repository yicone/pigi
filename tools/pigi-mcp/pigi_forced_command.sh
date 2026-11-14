#!/bin/sh
# Server-side forced command for the Billing-restricted SSH key (ACM-963).
#
# authorized_keys pins this script for exactly one dedicated key. The script
# NEVER executes SSH_ORIGINAL_COMMAND: it compares the request with one pinned,
# account-scoped, read-only pigi-mcp pipeline, records a sanitized event in a
# fail-closed ledger, and execs only the fixed pipeline. No code path runs
# attacker-controlled input.
#
# Authorization inputs are the literals below only — never the environment.
# The pinned interpreter is re-exec'd via `env -i`, so inherited PYTHONPATH /
# PYTHONHOME / IFS / startup variables cannot reach it. Remaining sshd-side
# conditions (AcceptEnv off, PermitUserEnvironment off, no ~/.ssh/environment,
# no unvetted ~/.ssh/rc) are verified at rollout; see
# docs/billing-ssh-transition.md.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
IFS=$(printf ' \t\nx'); IFS=${IFS%x}   # default IFS: space, tab, newline
umask 077
unset BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT

# --- pinned configuration (production literals) ---
# The offline self-test renders a throwaway copy with these four values
# replaced; it never edits this installed file.
readonly PIGI_MCP_PYTHON='/Users/tr/.pyenv/versions/3.11.13/bin/python3'
readonly PIGI_MCP_SCRIPT='/Users/tr/Workspace/pigi/tools/pigi-mcp/pigi_mcp.py'
readonly PIGI_MCP_ACCOUNT='adhielgona@gmail.com'
readonly PIGI_FC_LOG="$HOME/Library/Application Support/pigi/forced-command.log"
# --- end pinned configuration ---

refuse() {
    printf 'pigi-mcp: %s\n' "$1" >&2
    exit 1
}

# The ledger is a precondition for serving: if it cannot be validated or
# appended, refuse — same fail-closed rule as the adapter's audit_unavailable.
ledger_prepare() {
    dir=${PIGI_FC_LOG%/*}
    if [ ! -d "$dir" ]; then
        mkdir -m 700 "$dir" 2>/dev/null || return 1
    fi
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(stat -f %u "$dir" 2>/dev/null)" = "$(id -u)" ] || return 1
    [ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ] || return 1
    [ ! -L "$PIGI_FC_LOG" ] || return 1
    if [ ! -e "$PIGI_FC_LOG" ]; then
        : >> "$PIGI_FC_LOG" 2>/dev/null || return 1
    fi
    [ -f "$PIGI_FC_LOG" ] || return 1
    [ "$(stat -f %u "$PIGI_FC_LOG" 2>/dev/null)" = "$(id -u)" ] || return 1
    [ "$(stat -f %Lp "$PIGI_FC_LOG" 2>/dev/null)" = "600" ] || return 1
    [ "$(stat -f %l "$PIGI_FC_LOG" 2>/dev/null)" = "1" ] || return 1
    return 0
}

expected="$PIGI_MCP_PYTHON -B $PIGI_MCP_SCRIPT --account $PIGI_MCP_ACCOUNT"
original="${SSH_ORIGINAL_COMMAND-}"

# Sanitized metadata only: a charset-checked peer, request byte length, and a
# truncated SHA-256 fingerprint for attempt correlation. The raw request is
# never written — it may carry secrets, newlines, or control characters.
peer_raw="${SSH_CLIENT%% *}"
case $peer_raw in
    ''|*[!0-9A-Fa-f.:]*) peer='invalid' ;;
    *) peer=$peer_raw ;;
esac
req_len=${#original}
if [ -n "$original" ]; then
    req_fp=$(printf %s "$original" | shasum -a 256 | cut -c1-16)
else
    req_fp='-'
fi

ledger_prepare || refuse 'audit ledger unavailable; refusing.'

if [ -z "$original" ]; then
    result=deny; reason=empty
elif [ "$original" != "$expected" ]; then
    result=deny; reason=mismatch
elif [ ! -x "$PIGI_MCP_PYTHON" ] || [ ! -f "$PIGI_MCP_SCRIPT" ]; then
    result=deny; reason=pinned-unavailable
else
    result=allow; reason=exact
fi

if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$peer" "$result" "$reason" "$req_len" \
    "$req_fp" >> "$PIGI_FC_LOG" 2>/dev/null; then
    refuse 'audit ledger unavailable; refusing.'
fi

[ "$result" = allow ] || refuse 'command not permitted (pinned account-scoped read only).'

exec env -i HOME="$HOME" PATH="$PATH" PYTHONUTF8=1 \
    "$PIGI_MCP_PYTHON" -B "$PIGI_MCP_SCRIPT" --account "$PIGI_MCP_ACCOUNT"
