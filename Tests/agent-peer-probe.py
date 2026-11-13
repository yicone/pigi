"""Probe ONLY the disposable peer fixture. Never escalates, chmods or opens a DB."""
import argparse
import json
import os
from pathlib import Path
import socket
import stat

parser = argparse.ArgumentParser()
parser.add_argument("socket")
parser.add_argument("--same-uid", action="store_true", help="Smoke test only, NOT cross-UID evidence")
args = parser.parse_args()
path = Path(args.socket).resolve()
assert path.name == "agent.sock" and path.parent.name == "peer"
assert path.parent.parent.parent == Path("/private/tmp")
assert path.parent.parent.name.startswith("pigi-agent-settings.")
info = path.stat()
assert stat.S_ISSOCK(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
assert (info.st_uid == os.geteuid()) == args.same_uid, "Wrong identity for requested probe"
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(5)
    client.connect(str(path))
    try:
        client.sendall(b'{"version":1,"id":"peer-probe","method":"list"}\n')
    except BrokenPipeError:
        pass  # UID rejection occurs before the server reads any request bytes.
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = client.recv(4096)
        assert chunk and len(data) + len(chunk) <= 65536
        data.extend(chunk)
response = json.loads(data)
if args.same_uid:
    assert "error" not in response and response["result"]["items"] == []
    print("PASS: same-UID synthetic peer smoke (NOT cross-UID verification)")
else:
    assert "result" not in response and response["error"]["code"] == "unauthorized"
    print("PASS: actual different-UID connection rejected without mail")
