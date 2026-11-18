#!/bin/sh
# Trusted launch entry for the account-scoped one-shot pigi-mcp reader (ACM-980).
#
# Running `python3 pigi_oneshot.py` directly lets interpreter site hooks
# (sitecustomize, usercustomize, .pth files, PYTHONPATH) execute before the
# script's first line; no in-script check can prevent that. This launcher is
# therefore the ONLY supported entry: it scrubs the environment with `env -i`,
# then execs a pinned interpreter with `-I -S -B -X utf8` — no environment
# variables, no user site-packages, no .pth processing, explicit UTF-8 stdio —
# and marks the run with the trusted-entry flag the script's gate requires.
# The script refuses (exit 9) when started any other way.
#
# Authorization inputs are the literals below only — never the caller's
# environment or arguments beyond the fixed pass-through "$@".
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
IFS=$(printf ' \t\nx'); IFS=${IFS%x}
umask 077
unset BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE

# --- pinned configuration (production literals) ---
# The test suite renders a throwaway copy with these values replaced; it never
# edits this installed file.
readonly PIGI_OS_PYTHON='/Users/tr/.pyenv/versions/3.11.13/bin/python3'
readonly PIGI_OS_SCRIPT='/Users/tr/Workspace/pigi/tools/pigi-mcp/pigi_oneshot.py'
readonly PIGI_OS_HOME='/Users/tr'
# --- end pinned configuration ---

CONFIG_ERROR='{"contentTrust":"untrusted","error":"configuration_unavailable"}'

# Fail closed with the fixed JSON on stdout; stderr stays empty.
{ [ -x "$PIGI_OS_PYTHON" ] && [ -f "$PIGI_OS_SCRIPT" ]; } 2>/dev/null || {
    printf '%s\n' "$CONFIG_ERROR"
    exit 6
}

exec env -i HOME="$PIGI_OS_HOME" PATH="$PATH" \
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
    PIGI_ONESHOT_LAUNCHER=trusted-entry-v1 \
    "$PIGI_OS_PYTHON" -I -S -B -X utf8 "$PIGI_OS_SCRIPT" "$@"
