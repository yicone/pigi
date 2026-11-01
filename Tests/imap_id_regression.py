"""Exercise the real Swift transport against isolated TLS IMAP fixtures."""
import os
from pathlib import Path
import shlex
import socket
import ssl
import subprocess
import sys
import threading


build = Path(sys.argv[1])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(build / "cert.pem", build / "key.pem")


def check(operation, capability=True, response="OK", login_ok=True):
    commands = []
    errors = []
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(15)
    port = listener.getsockname()[1]

    def serve():
        try:
            raw, _ = listener.accept()
            raw.settimeout(15)
            with context.wrap_socket(raw, server_side=True) as conn:
                stream = conn.makefile("rb")
                conn.sendall(b"* OK fixture ready\r\n")
                identified = False
                while line := stream.readline():
                    tag, command = line.decode().rstrip("\r\n").split(" ", 1)
                    commands.append(command)
                    reply = ""
                    if command.startswith("LOGIN "):
                        assert len(commands) == 1
                        reply = "OK login" if login_ok else "NO invalid credentials"
                    elif command == "CAPABILITY":
                        assert len(commands) == 2
                        # Mixed case tests capability normalization.
                        caps = "IMAP4rev1 MOVE" + (" iD" if capability else "")
                        conn.sendall(f"* CAPABILITY {caps}\r\n".encode())
                        reply = "OK capability"
                    elif command.startswith("ID "):
                        assert capability and len(commands) == 3
                        assert command.startswith("ID (") and command.endswith(")")
                        fields = shlex.split(command[4:-1])
                        assert len(fields) == 6
                        fields = dict(zip(fields[::2], fields[1::2]))
                        assert fields["name"] == "pigi" and fields["vendor"] == "pigi"
                        assert fields["version"]
                        if response == "OK":
                            conn.sendall(b'* ID ("name" "Coremail")\r\n')
                        elif response == "NIL":
                            conn.sendall(b"* ID NIL\r\n")
                        elif response == "literal":
                            conn.sendall(b'* ID ("name" {8}\r\nCoremail)\r\n')
                        if response in ("BAD", "NO"):
                            reply = f"{response} identification rejected"
                        else:
                            identified = True
                            reply = "OK identification"
                    else:
                        assert not capability or identified, "Mailbox command before ID"
                        if command.startswith("SELECT "):
                            conn.sendall(b"* OK [UIDVALIDITY 123] valid\r\n")
                        elif command == "UID SEARCH ALL":
                            conn.sendall(b"* SEARCH 1\r\n")
                        elif command == "UID FETCH 1 (UID FLAGS)":
                            conn.sendall(b"* 1 FETCH (UID 1 FLAGS (\\Seen))\r\n")
                        elif command == 'LIST "" "*"':
                            conn.sendall(b'* LIST () "/" "INBOX"\r\n')
                        else:
                            assert command in ("LOGOUT", "UID STORE 1 +FLAGS (\\Seen)")
                        reply = "OK completed"
                    conn.sendall(f"{tag} {reply}\r\n".encode())
                    if command == "LOGOUT":
                        break
        except Exception as error:
            errors.append(error)
        finally:
            listener.close()

    worker = threading.Thread(target=serve)
    worker.start()
    expected_error = ""
    if not login_ok:
        expected_error = "登录失败:invalid credentials"
    elif response in ("BAD", "NO"):
        expected_error = "identification rejected"
    try:
        result = subprocess.run(
            [str(build / "imap-id-regression"), str(port), operation, expected_error],
            env={**os.environ, "PIGI_INSECURE_TLS": "1"}, capture_output=True,
            text=True, timeout=20,
        )
    finally:
        worker.join(timeout=20)
    assert not worker.is_alive(), "Fixture did not finish"
    assert not errors, errors
    assert result.returncode == 0, result.stderr
    if not login_ok:
        assert len(commands) == 1
    elif expected_error:
        assert len(commands) == 3
    else:
        assert commands[-1] == "LOGOUT"
        assert sum(c.startswith("ID ") for c in commands) == int(capability)
    print(f"PASS: {operation}, ID={capability}, response={response}, login={login_ok}")


for operation in ("probe", "sync", "flags"):
    for response in ("OK", "NIL", "literal"):
        check(operation, response=response)
    check(operation, capability=False)
for response in ("NO", "BAD"):
    check("probe", response=response)
check("probe", login_ok=False)
