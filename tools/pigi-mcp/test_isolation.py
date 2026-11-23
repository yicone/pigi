"""Default isolation shared by the synthetic test suites (not a test module).

Every suite calls `module_setup()` from setUpModule. From then on, in this
process, every default that used to resolve to the real HOME resolves to a
temporary sentinel home instead: the pinned home, the default agent.sock and
audit paths, and the defaults bound into Context/SocketClient/Audit. A
listener (the tripwire) sits at the sentinel agent.sock, so any code that
falls back to a default path is recorded and fails the test run instead of
reaching a real socket. Spawning the un-isolated repo entry points
(pigi_oneshot.py, pigi_oneshot_full.py, pigi_oneshot.sh,
pigi_forced_command.sh) is refused before a process exists.
"""
import json
import os
from pathlib import Path
import pwd
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

import audit
import pigi_mcp
import pigi_oneshot
import transport

HERE = Path(__file__).resolve().parent
REAL_PINNED_HOME = pigi_oneshot.PINNED_HOME
REAL_SOCKET = transport.DEFAULT_SOCKET
REAL_AUDIT = audit.DEFAULT_AUDIT
UNISOLATED_ENTRY_POINTS = frozenset(
    os.path.realpath(HERE / name) for name in (
        "pigi_oneshot.py", "pigi_oneshot_full.py", "pigi_oneshot.sh",
        "pigi_forced_command.sh"))
_active = None


def real_homes():
    return {os.path.realpath(os.path.expanduser("~")),
            os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir),
            os.path.realpath(REAL_PINNED_HOME)}


def short_base():
    """A writable temp base short enough for AF_UNIX fixture paths."""
    suffix = os.path.join("po-s-XXXXXXXX", "h", "Library", "Application Support",
                          "pigi", "agent.sock")
    for base in ("/tmp", "/private/tmp", "/var/tmp", tempfile.gettempdir()):
        if (base and os.path.isdir(base) and os.access(base, os.W_OK)
                and len(os.fsencode(os.path.join(os.path.realpath(base),
                                                 suffix))) <= 90):
            return base
    raise AssertionError("no short writable temp base for AF_UNIX fixtures")


def refuse_unisolated_entry(item):
    """AssertionError when `item` names a repo entry point that still carries
    the real pinned home (only isolated copies may be executed)."""
    try:
        path = os.path.realpath(os.fsdecode(item))
    except (TypeError, ValueError):
        return
    if path in UNISOLATED_ENTRY_POINTS:
        raise AssertionError("refusing to run un-isolated entry point: %s" % path)


class Tripwire(threading.Thread):
    """Listener at the sentinel agent.sock. It never answers: any recorded
    connection means something fell back to a default path."""

    def __init__(self, endpoint):
        super().__init__(daemon=True)
        self.endpoint = endpoint
        self.connections = 0
        self.requests = []
        self.ready = threading.Event()
        self.halt = threading.Event()

    def reset(self):
        self.connections = 0
        self.requests = []

    def run(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.endpoint)
        os.chmod(self.endpoint, 0o600)
        listener.listen(8)
        listener.settimeout(0.2)
        self.ready.set()
        try:
            while not self.halt.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    self.connections += 1
                    try:
                        connection.settimeout(1)
                        data = b""
                        while not data.endswith(b"\n"):
                            chunk = connection.recv(65536)
                            if not chunk:
                                break
                            data += chunk
                        self.requests.append(json.loads(data)["method"])
                    except (OSError, ValueError, KeyError, TypeError):
                        pass
        finally:
            listener.close()

    def stop(self):
        self.halt.set()
        self.join(4)


def _swap_defaults(function, old_new):
    """Replace default values equal to a key of old_new; return the original."""
    original = function.__defaults__
    function.__defaults__ = tuple(old_new.get(value, value) for value in original)
    return original


class Sentinel:
    def __init__(self, base, accounts):
        self.root = Path(tempfile.mkdtemp(prefix="po-s-", dir=base))
        os.chmod(self.root, 0o700)
        self.home = self.root / "h"
        support = self.home / "Library" / "Application Support"
        for directory in (self.home, self.home / "Library", support,
                          support / "pigi", support / "pigi-mcp"):
            directory.mkdir(exist_ok=True)
            os.chmod(directory, 0o700)
        self.socket = support / "pigi" / "agent.sock"
        self.audit = support / "pigi-mcp" / "audit.sqlite3"
        for name, doc in accounts.items():
            path = support / "pigi" / name
            path.write_text(json.dumps(doc))
            os.chmod(path, 0o600)
        self.tripwire = Tripwire(str(self.socket))
        self.tripwire.start()
        if not self.tripwire.ready.wait(3):
            raise AssertionError("tripwire listener did not start")

    def assert_quiet(self):
        if self.tripwire.connections or self.tripwire.requests:
            seen = (self.tripwire.connections, list(self.tripwire.requests))
            self.tripwire.reset()
            raise AssertionError("a default socket path was used: %r" % (seen,))


def active():
    if _active is None:
        raise AssertionError("module_setup() was not called: refusing to run "
                             "without the default isolation")
    return _active


def module_setup(accounts=None):
    """Install the default isolation for this test module; undone by the
    module cleanup. `accounts` maps config file names to synthetic documents
    written into the sentinel home."""
    global _active
    if _active is not None:
        raise AssertionError("default isolation already installed")
    sentinel = Sentinel(short_base(), accounts or {})
    patches = [
        mock.patch.object(pigi_oneshot, "PINNED_HOME", str(sentinel.home)),
        mock.patch.object(transport, "DEFAULT_SOCKET", sentinel.socket),
        mock.patch.object(audit, "DEFAULT_AUDIT", sentinel.audit),
        mock.patch.object(pigi_oneshot, "DEFAULT_SOCKET", sentinel.socket),
        mock.patch.object(pigi_oneshot, "DEFAULT_AUDIT", sentinel.audit),
        mock.patch.object(pigi_mcp, "DEFAULT_SOCKET", sentinel.socket),
        mock.patch.object(pigi_mcp, "DEFAULT_AUDIT", sentinel.audit),
    ]
    original_popen = subprocess.Popen.__init__

    def guarded_popen(self, args, *more, **kwargs):
        try:
            for item in (args if isinstance(args, (list, tuple)) else [args]):
                refuse_unisolated_entry(item)
        except AssertionError:
            # The refused object still reaches __del__; mark it so it exits
            # quietly instead of raising an unraisable AttributeError.
            self._child_created = False
            raise
        return original_popen(self, args, *more, **kwargs)

    patches.append(mock.patch.object(subprocess.Popen, "__init__", guarded_popen))
    defaults = []
    for function, mapping in (
            (pigi_oneshot.Context.__init__,
             {REAL_SOCKET: sentinel.socket, REAL_AUDIT: sentinel.audit}),
            (transport.SocketClient.__init__, {REAL_SOCKET: sentinel.socket}),
            (audit.Audit.__init__, {REAL_AUDIT: sentinel.audit})):
        defaults.append((function, _swap_defaults(function, mapping)))

    def restore():
        global _active
        for function, original in defaults:
            function.__defaults__ = original
        for patcher in reversed(started):
            patcher.stop()
        sentinel.tripwire.stop()
        _active = None

    started = []
    try:
        for patcher in patches:
            patcher.start()
            started.append(patcher)
    except BaseException:
        restore()
        raise
    unittest.addModuleCleanup(restore)
    unittest.addModuleCleanup(sentinel.assert_quiet)
    _active = sentinel
    return sentinel
