"""Loopback-only TLS IMAP fixture; verifies incremental fetches on the wire."""
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading

build = Path(sys.argv[1])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(build / 'cert.pem', build / 'key.pem')
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(3)
listener.settimeout(30)
errors = []
bodies = []


def message(subject):
    return (f'From: Sender <sender@example.test>\r\nSubject: {subject}\r\n'
            'MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="mixed"\r\n\r\n'
            '--mixed\r\nContent-Type: text/plain; charset=utf-8\r\n'
            'Content-Transfer-Encoding: quoted-printable\r\n\r\nplain=20body\r\n'
            '--mixed\r\nContent-Type: text/plain; name="note.txt"\r\n'
            'Content-Disposition: attachment; filename="note.txt"\r\n'
            'Content-Transfer-Encoding: base64\r\n\r\nbm90ZQ==\r\n--mixed--\r\n').encode()


def serve():
    try:
        # Connections 0-3 are the sync phases; connection 4 probes an accepted LOGIN
        # and connection 5 a rejected one for the password-rotation regression.
        for phase in range(6):
            raw, _ = listener.accept()
            raw.settimeout(20)
            with context.wrap_socket(raw, server_side=True) as conn:
                stream = conn.makefile('rb')
                conn.sendall(b'* OK fixture\r\n')
                while line := stream.readline():
                    tag, cmd = line.decode().rstrip('\r\n').split(' ', 1)
                    if cmd.startswith('LOGIN '):
                        if 'wrong-password' in cmd:
                            conn.sendall(f'{tag} NO [AUTHENTICATIONFAILED] invalid credentials\r\n'.encode())
                            continue
                    elif cmd == 'CAPABILITY':
                        conn.sendall(b'* CAPABILITY IMAP4rev1\r\n')
                    elif cmd.startswith('SELECT '):
                        conn.sendall(f'* OK [UIDVALIDITY {200 if phase >= 2 else 100}] valid\r\n'.encode())
                    elif cmd == 'UID SEARCH ALL':
                        conn.sendall(b'* SEARCH 1 2\r\n' if phase in (1, 3) else b'* SEARCH 1\r\n')
                    elif cmd.startswith('UID FETCH '):
                        ids = cmd.split()[2].split(',')
                        full = 'BODY.PEEK[]' in cmd
                        if full:
                            bodies.append((phase, ids))
                        for uid in ids:
                            flags = '\\Seen' if phase == 1 and uid == '1' else ''
                            prefix = f'* {uid} FETCH (UID {uid} FLAGS ({flags})'
                            if full:
                                subject = 'Replacement' if phase >= 2 and uid == '1' else ('First' if uid == '1' else 'Second')
                                data = message(subject)
                                conn.sendall((prefix + f' BODY[] {{{len(data)}}}\r\n').encode() + data + b')\r\n')
                            else:
                                conn.sendall((prefix + ')\r\n').encode())
                    elif cmd != 'LOGOUT':
                        raise AssertionError(cmd)
                    conn.sendall(f'{tag} OK done\r\n'.encode())
                    if cmd == 'LOGOUT':
                        break
    except Exception as error:
        errors.append(error)
    finally:
        listener.close()


worker = threading.Thread(target=serve)
worker.start()
try:
    result = subprocess.run([str(build / 'engine-sync-regression'), str(listener.getsockname()[1]),
                             str(Path(__file__).parent / 'fixtures')],
                            env={**os.environ, 'PIGI_INSECURE_TLS': '1'}, timeout=60)
finally:
    worker.join(timeout=35)
assert not worker.is_alive(), 'Fixture did not terminate'
assert not errors, errors
assert result.returncode == 0, result.returncode
assert bodies == [(0, ['1']), (1, ['2']), (2, ['1']), (3, ['2'])], bodies
print('PASS: unchanged UID body skipped; reused UID body fetched after reset')
