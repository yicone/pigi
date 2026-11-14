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

# dev:inode of a path (lstat) — the identity pair.
id_of() {
    stat -f '%d:%i' "$1" 2>/dev/null
}

# Real fstat metadata of an open descriptor as dev:ino:uid:mode:nlink. stat(1)
# on /dev/fd/N reports the fdesc node, not the open file, so the descriptor's
# own device and mode must come from fstat(2).
fd_meta() {
    /usr/bin/perl -e 'open(F,"<&=",shift) or exit 1; @s=stat(F); \
        printf "%d:%d:%d:%o:%d",$s[0],$s[1],$s[4],$s[2]&07777,$s[3]' "$1" \
        2>/dev/null
}

# Directory-side validation: leaf dir plus every ancestor to /. Must pass
# BEFORE any mkdir or file create — a refused ancestor must never gain a
# created object as a side effect. On success dir_id holds the validated
# directory's dev:inode so later steps bind to the object, not the path.
ledger_dirs_ok() {
    dir=$1
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(stat -f %u "$dir" 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ] || return 1
    cur=$dir
    while :; do
        dir_component_ok "$cur" || return 1
        [ "$cur" = / ] && break
        cur=${cur%/*}
        [ -n "$cur" ] || cur=/
    done
    dir_id=$(stat -f %d:%i "$dir" 2>/dev/null) || return 1
}

# Full path validation; prints the ledger's dev:inode on success. Run before
# AND after the open so a same-UID swap in either window is caught: a chmod or
# replacement during the check→open window re-fails policy on the second pass.
ledger_path_ok() {
    ledger_dirs_ok "$1" || return 1
    [ ! -L "$PIGI_FC_LOG" ] || return 1
    [ -f "$PIGI_FC_LOG" ] || return 1
    [ "$(stat -f %u "$PIGI_FC_LOG" 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %Lp "$PIGI_FC_LOG" 2>/dev/null)" = "600" ] || return 1
    [ "$(stat -f %l "$PIGI_FC_LOG" 2>/dev/null)" = "1" ] || return 1
    id_of "$PIGI_FC_LOG"
}

# Descriptor policy on fd 9: fstat must name the validated object and its
# real owner/mode/link count must still meet ledger policy. Used inside the
# emit statement itself so no check→write gap exists between them.
ledger_fd_ok() {
    fdinfo=$(fd_meta 9) || return 1
    [ "$(printf %s "$fdinfo" | cut -d: -f1,2)" = "$LEDGER_ID" ] || return 1
    [ "$(printf %s "$fdinfo" | cut -d: -f3-)" = "$euid:600:1" ] || return 1
}

# Canonical-path policy: every ancestor, the leaf directory, and the ledger
# file must still validate, and the path must still name the pinned inode.
# Run at every gate — a same-UID change anywhere (swap, chmod, hard link,
# dir-to-symlink) fails one of these checks.
ledger_bound() {
    [ "$(ledger_path_ok "$dir")" = "$LEDGER_ID" ]
}

ledger_gate() {
    ledger_fd_ok && ledger_bound
}

# Refusal cleanup inside ledger_prepare: remove the leaf dir only when the
# path still names the fd-pinned object this run created (dev:inode of fd 8)
# and it is empty. Never deletes a swapped-in pre-existing directory by path
# alone; a swapped-out self-created dir is left as harmless residue.
prep_cleanup() {
    [ -n "$made_dir" ] || return 0
    exec 8<&-
    [ "$(stat -f %d:%i "$dir" 2>/dev/null)" = "$made_id" ] || return 0
    rmdir "$dir" 2>/dev/null
}

# The ledger is a precondition for serving: if it cannot be validated, opened,
# or appended, refuse — the same fail-closed rule as the adapter's
# audit_unavailable. On success fd 9 is an append descriptor pinned to the
# fully validated inode, and dir/LEDGER_ID name it for later gates.
ledger_prepare() {
    case $PIGI_FC_LOG in
        /*) ;;
        *) return 1 ;;
    esac
    dir=${PIGI_FC_LOG%/*}
    leaf=${PIGI_FC_LOG##*/}
    [ -n "$dir" ] && [ -n "$leaf" ] || return 1
    made_dir= ; made_id=
    if [ ! -d "$dir" ]; then
        # Ancestors of the missing leaf must pass BEFORE mkdir — a refused
        # ancestor must never gain a created directory as a side effect.
        anc=${dir%/*}
        [ -n "$anc" ] || anc=/
        cur=$anc
        while :; do
            dir_component_ok "$cur" || return 1
            [ "$cur" = / ] && break
            cur=${cur%/*}
            [ -n "$cur" ] || cur=/
        done
        mkdir -m 700 "$dir" 2>/dev/null || return 1
        # Pin the just-created dir on fd 8 immediately; the mkdir→pin gap is
        # the only instruction-scale residual where a swap could pin the wrong
        # object — every later check compares against this fstat.
        made_dir=1
        { exec 8<"$dir" || return 1; } 2>/dev/null
        made_id=$(fd_meta 8 | cut -d: -f1,2)
        [ -n "$made_id" ] || { prep_cleanup; return 1; }
    fi
    # Leaf dir + ancestors must pass BEFORE any file creation; dir_id is the
    # validated object's identity captured inside the same pass.
    ledger_dirs_ok "$dir" || { prep_cleanup; return 1; }
    # If this run created the leaf dir, the path must still name exactly that
    # object — a same-UID swap in the pin→validate window refuses here, and
    # cleanup then sees the substitute (inode differs) and never rmdir's it.
    [ -z "$made_dir" ] || [ "$dir_id" = "$made_id" ] || { prep_cleanup; return 1; }
    # A link at the ledger path is refused before ANY create attempt.
    [ -L "$PIGI_FC_LOG" ] && { prep_cleanup; return 1; }
    if [ ! -e "$PIGI_FC_LOG" ]; then
        # The create is bound to the validated directory OBJECT, not its
        # path: pin the dir with an fd, fstat the fd against the validated
        # dev:inode captured by ledger_dirs_ok, fchdir into it, then create
        # the leaf relative to that cwd. A path swap before the pin fails the
        # fstat compare; a swap after the pin cannot redirect the create.
        # O_NOFOLLOW still covers a leaf-level link planted in the remaining
        # instruction-scale gap.
        /usr/bin/perl -e 'use Fcntl;
            sysopen(D,$ARGV[0],O_RDONLY|O_DIRECTORY) or exit 1;
            my @s=stat(D); ($s[0]==$ARGV[2] && $s[1]==$ARGV[3]) or exit 2;
            chdir(D) or exit 3;
            sysopen(F,$ARGV[1],O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600) or exit 4;
            close F' \
            "$dir" "$leaf" "${dir_id%%:*}" "${dir_id##*:}" 2>/dev/null \
            || { prep_cleanup; return 1; }
    fi
    exec 8<&-  # release the mkdir pin if one was taken
    LEDGER_ID=$(ledger_path_ok "$dir") || return 1
    # A bare `exec 9>>... 2>/dev/null` would also send fd 2 to /dev/null for
    # the rest of the script; the group confines the suppression to open errors.
    { exec 9>>"$PIGI_FC_LOG" || return 1; } 2>/dev/null
    [ -f /dev/fd/9 ] || return 1
    # The open descriptor must name the very object just validated, and the
    # post-open pass re-runs every path check so anything staged inside the
    # check→open window is caught here.
    ledger_fd_ok || return 1
    ledger_bound || return 1
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

if ! ledger_gate; then
    result=deny; reason=detached
elif [ -z "$original" ]; then
    result=deny; reason=empty
elif [ "$original" != "$expected" ]; then
    result=deny; reason=mismatch
elif [ ! -x "$PIGI_MCP_PYTHON" ] || [ ! -f "$PIGI_MCP_SCRIPT" ]; then
    result=deny; reason=pinned-unavailable
else
    result=allow; reason=exact
fi

# fd 9 stays open through the gates so each check can fstat it; refuse()
# exits anyway, and the exec below closes it in the child via `9>&-`.
# The emit statement re-checks the descriptor AND the canonical path (for
# allow) inside the same command — a staged change refuses BEFORE any byte
# is written, never "write first, refuse later". Every expansion inside the
# statement is a precomputed variable; no command substitution runs between
# the checks and the write. A change landing between the last check and the
# write is the documented instruction-scale residual. deny records still
# reach the pinned inode even when the canonical path detached.
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! { ledger_fd_ok \
        && { [ "$result" = deny ] || ledger_bound; } \
        && printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ts" "$peer" "$result" "$reason" "$req_len" "$req_fp" >&9; } \
    2>/dev/null; then
    refuse 'audit ledger unavailable; refusing.'
fi
[ "$result" = allow ] || refuse 'command not permitted (pinned account-scoped read only).'
# Final gate immediately before exec: full fd + path + ancestor checks — a
# detach or policy change staged between emit and now still refuses. A swap
# in the remaining instruction-scale window cannot redirect the (already
# fd-written) record; its real residual is documented in the runbook.
ledger_gate || refuse 'audit ledger detached; refusing.'

# The wire contract stays "python -B <script> --account <acct>"; the server
# adds -E -S -X utf8 isolation flags itself, so the approved request and the
# hardened interpreter invocation differ deliberately.
exec env -i HOME="$PIGI_FC_HOME" PATH="$PATH" \
    "$PIGI_MCP_PYTHON" -B -E -S -X utf8 "$PIGI_MCP_SCRIPT" --account "$PIGI_MCP_ACCOUNT" \
    9>&-
