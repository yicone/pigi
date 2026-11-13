#!/usr/bin/env python3
"""Linux-compatible SSH stdio launcher; no connector registration or credential setup."""
import argparse
import os
import re
import shlex
import sys


def ssh_command(host, script, account, python="python3"):
    # The destination cannot be an SSH option, URL, or arbitrary command.
    if not re.fullmatch(r"(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9_][A-Za-z0-9_.-]*", host):
        raise ValueError("Invalid SSH destination.")
    if not script.startswith("/") or not script.endswith("/pigi_mcp.py") or "\x00" in script:
        raise ValueError("Use an absolute remote pigi_mcp.py path.")
    if not account.strip() or len(account.encode("utf-8")) > 1024 or "\x00" in account:
        raise ValueError("Invalid account scope.")
    if python != "python3" and (not python.startswith("/") or "\x00" in python):
        raise ValueError("Use python3 or an absolute Python executable path.")
    # OpenSSH executes one command through the remote shell: quote every argument there.
    remote = shlex.join([python, "-B", script, "--account", account])
    return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", host, remote]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="Previously authorized SSH host or user@host.")
    parser.add_argument("--remote-script", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--remote-python", default="python3")
    args = parser.parse_args()
    try:
        command = ssh_command(args.host, args.remote_script, args.account, args.remote_python)
    except ValueError as error:
        parser.error(str(error))
    try:
        # Inherit stdio directly: no PTY, body buffering, shell on Linux, or local mail access.
        os.execvp(command[0], command)
    except OSError:
        print("pigi-mcp: SSH unavailable.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
