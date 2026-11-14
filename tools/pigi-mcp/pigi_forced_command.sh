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
# The pinned interpreter is re-exec'd via `env -i` with -E -S -X utf8: no
# PYTHON* variables, no site processing (no user/global site-packages, no .pth
# or other startup files), explicit UTF-8 stdio; imports resolve to the
# script's own directory plus the stdlib. Remaining sshd-side conditions
# (AcceptEnv off, PermitUserEnvironment off, no ~/.ssh/environment, no unvetted
# ~/.ssh/rc) are verified at rollout; see docs/billing-ssh-transition.md.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
IFS=$(printf ' \t\nx'); IFS=${IFS%x}
umask 077
unset BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT
# If a write is capped by RLIMIT_FSIZE, take the error instead of SIGXFSZ.
trap '' XFSZ 2>/dev/null || true

# --- pinned configuration (production literals) ---
# The offline self-test renders a throwaway copy with these five values
# replaced; it never edits this installed file.
readonly PIGI_FC_HOME='/Users/tr'
readonly PIGI_MCP_PYTHON='/Users/tr/.pyenv/versions/3.11.13/bin/python3'
readonly PIGI_MCP_SCRIPT='/Users/tr/Workspace/pigi/tools/pigi-mcp/pigi_mcp.py'
readonly PIGI_MCP_ACCOUNT='adhielgona@gmail.com'
readonly PIGI_FC_LOG='/Users/tr/Library/Application Support/pigi/forced-command.log'
# --- end pinned configuration ---

refuse() {
    printf 'pigi-mcp: %s\n' "$1" >&2
    exit 1
}

euid=$(id -u)

# Ancestor component: a real directory, not a symlink, owned by us or root,
# and not replaceable by others — either not group/world writable, or a sticky
# world-writable directory like /tmp where non-owners cannot rename entries.
dir_component_ok() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    m=$(stat -f %p "$1" 2>/dev/null) && [ -n "$m" ] || return 1
    u=$(stat -f %u "$1" 2>/dev/null) || return 1
    [ $((0$m & 022)) -eq 0 ] || [ $((0$m & 01000)) -ne 0 ] || return 1
    [ "$u" = "$euid" ] || [ "$u" = 0 ] || return 1
}

# The ledger is a precondition for serving: if it cannot be validated, opened,
# or appended, refuse — the same fail-closed rule as the adapter's
# audit_unavailable. On success fd 9 is the pinned append descriptor.
ledger_prepare() {
    case $PIGI_FC_LOG in
        /*) ;;
        *) return 1 ;;
    esac
    dir=${PIGI_FC_LOG%/*}
    [ -n "$dir" ] || return 1
    if [ ! -d "$dir" ]; then
        mkdir -m 700 "$dir" 2>/dev/null || return 1
    fi
    # Leaf directory: strictly private.
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(stat -f %u "$dir" 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ] || return 1
    # Every ancestor up to / must be a non-writable real directory owned by
    # us or root; a writable or symlinked ancestor can swap the leaf.
    cur=$dir
    while :; do
        dir_component_ok "$cur" || return 1
        [ "$cur" = / ] && break
        cur=${cur%/*}
        [ -n "$cur" ] || cur=/
    done
    # The ledger file itself: a singly-linked regular file we own at 0600,
    # created only when absent and always re-validated afterwards.
    [ ! -L "$PIGI_FC_LOG" ] || return 1
    if [ ! -e "$PIGI_FC_LOG" ]; then
        : >> "$PIGI_FC_LOG" 2>/dev/null || return 1
    fi
    [ -f "$PIGI_FC_LOG" ] || return 1
    [ "$(stat -f %u "$PIGI_FC_LOG" 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %Lp "$PIGI_FC_LOG" 2>/dev/null)" = "600" ] || return 1
    [ "$(stat -f %l "$PIGI_FC_LOG" 2>/dev/null)" = "1" ] || return 1
    # Pin an append descriptor, then verify the OPEN file is the very inode we
    # just validated — a path swap after the checks cannot redirect the write.
    i_path=$(stat -f %i "$PIGI_FC_LOG" 2>/dev/null) || return 1
    # A bare `exec 9>>... 2>/dev/null` would also send fd 2 to /dev/null for
    # the rest of the script; the group confines the suppression to open errors.
    { exec 9>>"$PIGI_FC_LOG" || return 1; } 2>/dev/null
    [ -f /dev/fd/9 ] || return 1
    [ "$(stat -f %i /dev/fd/9 2>/dev/null)" = "$i_path" ] || return 1
    [ "$(stat -f %u /dev/fd/9 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %l /dev/fd/9 2>/dev/null)" = "1" ] || return 1
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
    "$req_fp" >&9 2>/dev/null; then
    exec 9>&-
    refuse 'audit ledger unavailable; refusing.'
fi
exec 9>&-

[ "$result" = allow ] || refuse 'command not permitted (pinned account-scoped read only).'

# The wire contract stays "python -B <script> --account <acct>"; the server
# adds -E -S -X utf8 isolation flags itself, so the approved request and the
# hardened interpreter invocation differ deliberately.
exec env -i HOME="$PIGI_FC_HOME" PATH="$PATH" \
    "$PIGI_MCP_PYTHON" -B -E -S -X utf8 "$PIGI_MCP_SCRIPT" --account "$PIGI_MCP_ACCOUNT"
