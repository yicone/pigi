"""Synthetic fixtures only: fake agent.sock in a short temp dir, never real mail or HOME."""
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import pwd
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import audit
import pigi_oneshot
import pigi_oneshot_full
from pigi_mcp import TRUST_NOTICE
import transport

SCRIPT = Path(__file__).with_name("pigi_oneshot.py")
FULL_SCRIPT = SCRIPT.with_name("pigi_oneshot_full.py")
LAUNCHER = SCRIPT.with_name("pigi_oneshot.sh")
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DOCS = REPO_ROOT / "docs" / "pigi-oneshot.md"
ORIGINAL_PINNED_HOME = pigi_oneshot.PINNED_HOME
ACCOUNT = "target@example.com"
FULL_ACCOUNT = "full@example.net"
ALLOWED = "allowed@example.com"
OTHER = "other@example.org"
NOW = 1_800_000_000_000
CAPS = ["filters", "scoped_accounts"]
SENTINEL = "BODY_SENTINEL_DO_NOT_LEAK"
FIXED_ERROR_CODES = {"invalid_request", "unsupported_version", "method_not_found", "not_found",
                     "unauthorized", "permission_denied", "audit_unavailable", "too_large",
                     "timeout", "internal_error", "unavailable", "unsupported_server",
                     "invalid_response", "upstream_unavailable"}
USAGE_DOC = {"contentTrust": "untrusted", "error": "invalid_arguments"}
CONFIG_DOC = {"contentTrust": "untrusted", "error": "configuration_unavailable"}
INTERNAL_DOC = {"contentTrust": "untrusted", "error": "internal_error"}

_LAUNCHER_PIN = re.search(r"^readonly PIGI_OS_PYTHON='([^']*)'",
                          LAUNCHER.read_text(), re.M)
if _LAUNCHER_PIN is None:
    raise AssertionError("launcher pinned interpreter literal not found")
PINNED_LAUNCHER_PYTHON = _LAUNCHER_PIN.group(1)


def real_homes():
    return {os.path.realpath(os.path.expanduser("~")),
            os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir),
            os.path.realpath(ORIGINAL_PINNED_HOME)}


_NATIVE_MAGICS = frozenset({
    b"\x7fELF",                            # ELF
    b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf",  # Mach-O big-endian 32/64-bit
    b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe",  # Mach-O little-endian 32/64-bit
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",  # Mach-O fat/universal
})
# The newest feature the wrapper code uses is bytes.removesuffix (3.9).
MIN_TEST_PYTHON = (3, 9)
TEST_PYTHON_CANDIDATES = ("/opt/homebrew/bin/python3",
                          "/usr/local/bin/python3", "/usr/bin/python3")


def _is_native_binary(path):
    """True when the first bytes are Mach-O or ELF magic — a real executable,
    never a #! script or other text wrapper around one."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(4)
    except OSError:
        return False
    return head in _NATIVE_MAGICS


def check_interpreter(interpreter):
    """Refuse the pinned production interpreter in any spelling, and refuse
    any script/wrapper standing in for an interpreter — only a native binary
    may be spawned or rendered into a launcher."""
    forbidden = {os.path.normpath(PINNED_LAUNCHER_PYTHON),
                 os.path.realpath(PINNED_LAUNCHER_PYTHON)}
    if (os.path.normpath(interpreter) in forbidden
            or os.path.realpath(interpreter) in forbidden):
        raise AssertionError("refusing pinned production interpreter: %s"
                             % interpreter)
    if os.path.exists(interpreter) and not _is_native_binary(interpreter):
        raise AssertionError("refusing non-native interpreter path: %s"
                             % interpreter)


def validate_test_interpreter(path):
    """Static checks only — the candidate is never executed here."""
    if not path or not os.path.isfile(path):
        raise AssertionError("test interpreter is not a file: %r" % path)
    if not os.access(path, os.X_OK):
        raise AssertionError("test interpreter not executable: %s" % path)
    check_interpreter(path)
    return path


def assert_isolated(home, config_path, socket_path, audit_db, interpreter=None):
    """Refuse (AssertionError) when any path resolves to a real location."""
    homes = real_homes()
    resolved_home = os.path.realpath(home)
    if resolved_home in homes:
        raise AssertionError("refusing to run against real home: %s" % resolved_home)
    protected = []
    for real in homes:
        base = os.path.join(real, "Library", "Application Support")
        protected += [os.path.join(base, "pigi"), os.path.join(base, "pigi-mcp")]
    for label, path in (("config", config_path), ("socket", socket_path),
                        ("audit", audit_db)):
        resolved = os.path.realpath(path)
        for root in protected:
            if resolved == root or resolved.startswith(root + os.sep):
                raise AssertionError("refusing real %s path: %s" % (label, resolved))
    if os.path.realpath(socket_path) == os.path.realpath(transport.DEFAULT_SOCKET):
        raise AssertionError("refusing default socket path")
    if os.path.realpath(audit_db) == os.path.realpath(audit.DEFAULT_AUDIT):
        raise AssertionError("refusing default audit path")
    if interpreter is not None:
        check_interpreter(interpreter)


def pick_temp_root():
    """A short writable temp base so AF_UNIX fixture paths stay <=90 bytes."""
    suffix = os.path.join("po-XXXXXXXX", "00000000", "Library",
                          "Application Support", "pigi", "agent.sock")
    for base in ("/tmp", "/private/tmp", "/var/tmp", tempfile.gettempdir()):
        if not base or not os.path.isdir(base) or not os.access(base, os.W_OK):
            continue
        if len(os.fsencode(os.path.join(os.path.realpath(base), suffix))) <= 90:
            return base
    raise AssertionError("no short writable temp base for AF_UNIX fixtures")


_SYNTHETIC_PYTHON = None


def _test_python_version(path):
    """version_info[:2] of a validated interpreter via a fast probe, or None."""
    try:
        probe = subprocess.run(
            [path, "-I", "-S", "-c",
             "import sys; print('%d %d' % sys.version_info[:2])"],
            capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if probe.returncode != 0:
        return None
    parts = probe.stdout.split()
    if len(parts) != 2:
        return None
    try:
        return (int(parts[0]), int(parts[1]))
    except ValueError:
        return None


def synthetic_python():
    """Resolve a confirmed NON-production interpreter for subprocesses.

    The test-runner process itself may legitimately be the pinned interpreter
    on machines where the suite is launched with it — the guarantee here is
    only that no subprocess and no rendered launcher ever uses the pinned
    binary or a wrapper around it. Candidates are tried in order: an explicit
    PIGI_TEST_PYTHON override, sys.executable, then the fixed fallbacks.
    A set-but-invalid override fails closed rather than silently falling
    through; when nothing qualifies the suite raises instead of creating any
    file or temp dir."""
    global _SYNTHETIC_PYTHON
    if _SYNTHETIC_PYTHON is not None:
        return _SYNTHETIC_PYTHON
    override = os.environ.get("PIGI_TEST_PYTHON")
    candidates = ([override] if override
                  else [sys.executable, *TEST_PYTHON_CANDIDATES])
    errors = []
    for candidate in candidates:
        try:
            validate_test_interpreter(candidate)
        except AssertionError as exc:
            errors.append(str(exc))
            continue
        version = _test_python_version(candidate)
        if version is not None and version >= MIN_TEST_PYTHON:
            _SYNTHETIC_PYTHON = candidate
            return candidate
        errors.append("%s unusable or older than %s: %r"
                      % (candidate, MIN_TEST_PYTHON, version))
    if override:
        raise AssertionError("PIGI_TEST_PYTHON rejected: %s"
                             % "; ".join(errors))
    raise AssertionError("no non-production python interpreter available; "
                         "set PIGI_TEST_PYTHON (tried: %s)"
                         % "; ".join(errors))


def setUpModule():
    # Prove the guard is wired: the production defaults must trip it. Every
    # fixture below injects temp paths — the suite never uses real defaults.
    default_config = Path(ORIGINAL_PINNED_HOME).joinpath(*pigi_oneshot.CONFIG_PARTS)
    try:
        assert_isolated(ORIGINAL_PINNED_HOME, default_config,
                        transport.DEFAULT_SOCKET, audit.DEFAULT_AUDIT,
                        interpreter=PINNED_LAUNCHER_PYTHON)
    except AssertionError:
        pass
    else:
        raise AssertionError("isolation guard ignored real defaults")
    # ... and specifically the pinned production interpreter.
    with tempfile.TemporaryDirectory(prefix="po-g-") as tmp:
        try:
            assert_isolated(tmp, os.path.join(tmp, "oneshot.json"),
                            os.path.join(tmp, "agent.sock"),
                            os.path.join(tmp, "audit.sqlite3"),
                            interpreter=PINNED_LAUNCHER_PYTHON)
        except AssertionError:
            pass
        else:
            raise AssertionError("isolation guard ignored pinned interpreter")


class _BytesStdout:
    """Stand-in for sys.stdout exposing .buffer and text write()."""

    def __init__(self):
        self.buffer = io.BytesIO()

    def write(self, text):
        self.buffer.write(str(text).encode("utf-8"))

    def flush(self):
        pass


def make_message(message_id, sender=ALLOWED, **fields):
    message = {"account": ACCOUNT, "messageID": message_id, "date": NOW,
               "subject": "synthetic subject", "fromName": "Synthetic Sender",
               "fromEmail": sender, "snippet": "synthetic snippet",
               "unread": False, "starred": False, "status": "inbox"}
    message.update(fields)
    return message


def accounts_result():
    return {"accounts": [{"account": ACCOUNT, "kind": "imap"}],
            "contentTrust": "untrusted", "capabilities": CAPS}


def search_result(items):
    return {"items": items, "contentTrust": "untrusted", "capabilities": CAPS}


def get_result(message, text):
    return {"message": message, "text": text,
            "contentTrust": "untrusted", "capabilities": CAPS}


class AgentError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def agent_handler(table):
    def handle(request):
        responder = table.get(request.get("method"))
        if responder is None:
            return {"version": 1, "id": request["id"],
                    "error": {"code": "method_not_found", "message": "method_not_found"}}
        try:
            result = responder(request.get("params") or {})
        except AgentError as error:
            return {"version": 1, "id": request["id"],
                    "error": {"code": error.code, "message": error.code}}
        return {"version": 1, "id": request["id"], "result": result}
    return handle


class FakeAgent(threading.Thread):
    """Protocol-v1 responder on a private socket; records every request frame."""

    def __init__(self, directory, table):
        super().__init__(daemon=True)
        self.endpoint = os.path.join(directory, "agent.sock")
        self.table = table
        self.requests = []
        self.errors = []
        self.ready = threading.Event()
        self.halt = threading.Event()

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
                    try:
                        connection.settimeout(5)
                        data = b""
                        while not data.endswith(b"\n"):
                            chunk = connection.recv(65536)
                            if not chunk:
                                break
                            data += chunk
                        request = json.loads(data)
                        self.requests.append(request)
                        response = agent_handler(self.table)(request)
                        connection.sendall(json.dumps(response).encode("utf-8") + b"\n")
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    except Exception as error:
                        self.errors.append(error)
        finally:
            listener.close()

    def stop(self):
        self.halt.set()
        self.join(4)


class OneshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="po-", dir=pick_temp_root())
        self.addCleanup(self.temp.cleanup)
        os.chmod(self.temp.name, 0o700)
        self.root = Path(self.temp.name)
        self.table = {}
        self.agent = FakeAgent(self.temp.name, self.table)
        self.agent.start()
        self.assertTrue(self.agent.ready.wait(3))
        self.addCleanup(self.stop_agent)
        self.ctx = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=self.agent.endpoint,
            audit_db=self.root / "audit.sqlite3", python=synthetic_python(),
            home=self.temp.name, now_ms=lambda: NOW)
        assert_isolated(self.temp.name, self.root / "oneshot.json",
                        self.ctx.socket_path, self.ctx.audit_db,
                        interpreter=self.ctx.python)

    def stop_agent(self):
        self.agent.stop()
        self.assertFalse(self.agent.is_alive())
        self.assertEqual(self.agent.errors, [])

    def invoke(self, argv, ctx=None):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code, out = pigi_oneshot.execute(argv, ctx or self.ctx)
        self.assertEqual(err.getvalue(), "")
        return code, out

    def parse(self, out):
        return json.loads(out.decode("utf-8").strip())

    def trusted_env(self, extra=None):
        env = {"HOME": self.temp.name, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               pigi_oneshot.TRUSTED_FLAG_NAME: pigi_oneshot.TRUSTED_FLAG_VALUE}
        if extra:
            env.update(extra)
        return env

    def run_python(self, argv, **kwargs):
        """Spawn a python subprocess; the interpreter is guard-checked first."""
        check_interpreter(str(argv[0]))
        return subprocess.run(argv, **kwargs)

    def cli(self, args):
        result = self.run_python(
            [synthetic_python(), "-I", "-S", "-B", "-X", "utf8",
             str(SCRIPT), *args],
            capture_output=True, timeout=20, env=self.trusted_env())
        self.assertEqual(result.stderr, b"")
        if result.stdout:
            json.loads(result.stdout)  # always a single JSON document
        return result

    def launch(self, launcher, argv, env=None):
        """Run a rendered launcher twice: merged stderr=STDOUT, then split."""
        merged = subprocess.run([str(launcher), *argv], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=20, env=env)
        split = subprocess.run([str(launcher), *argv], capture_output=True,
                               timeout=20, env=env)
        return merged, split

    def assert_json_contract(self, merged, split, code, doc=None):
        """stderr empty, stdout one bounded JSON doc, merged == stdout."""
        self.assertEqual(split.returncode, code)
        self.assertEqual(split.stderr, b"")
        self.assertLessEqual(len(split.stdout), pigi_oneshot.MAX_STDOUT)
        parsed = json.loads(split.stdout)
        self.assertEqual(parsed["contentTrust"], "untrusted")
        if doc is not None:
            self.assertEqual(parsed, doc)
        self.assertEqual(json.loads(merged.stdout), parsed)

    def render_launcher(self, directory, python, script, home):
        """Throwaway copy of pigi_oneshot.sh with the pinned literals replaced.
        The isolation guard runs first — a refused call writes nothing."""
        support = Path(home) / "Library" / "Application Support"
        assert_isolated(str(home), support / "pigi" / "oneshot.json",
                        support / "pigi" / "agent.sock",
                        support / "pigi-mcp" / "audit.sqlite3",
                        interpreter=str(python))
        rendered = Path(directory) / "pigi_oneshot.sh"
        text = LAUNCHER.read_text()
        for name, value in (("PIGI_OS_PYTHON", str(python)),
                            ("PIGI_OS_SCRIPT", str(script)),
                            ("PIGI_OS_HOME", str(home))):
            text, count = re.subn(r"^readonly %s=.*$" % name,
                                  "readonly %s='%s'" % (name, value), text,
                                  count=1, flags=re.M)
            self.assertEqual(count, 1, name)
            self.assertEqual(text.count("readonly %s='%s'" % (name, value)), 1)
        rendered.write_text(text)
        os.chmod(rendered, 0o755)
        return rendered

    def make_hooks(self):
        """A poisoned launch environment: sitecustomize, usercustomize and a
        .pth in the user-site tree, plus PYTHONPATH json/argparse poison and a
        BASH_ENV file — every hook writes a distinct canary file.
        Returns (env, canaries)."""
        hookdir = self.root / "hookdir"
        hookdir.mkdir()
        base = self.root / "userbase"
        canaries = {}

        def canary(name):
            path = self.root / ("canary-" + name)
            canaries[name] = path
            return path

        for name in ("sitecustomize", "json", "argparse"):
            (hookdir / (name + ".py")).write_text(
                "import os\nopen(%r, 'w').write('hit')\n" % str(canary(name)))
        bash_env = hookdir / "bash_env"
        bash_env.write_text("echo hit > '%s'\n" % canary("bash_env"))
        probe = self.run_python(
            [synthetic_python(), "-c",
             "import site; print(site.getusersitepackages())"],
            capture_output=True, timeout=20,
            env={"PYTHONUSERBASE": str(base),
                 "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        usersite = Path(probe.stdout.decode("utf-8").strip())
        usersite.mkdir(parents=True)
        (usersite / "usercustomize.py").write_text(
            "import os\nopen(%r, 'w').write('hit')\n" % str(canary("usercustomize")))
        (usersite / "canary.pth").write_text(
            "import os; open(%r, 'w').write('pth')" % str(canary("pth")))
        startup = hookdir / "startup.py"
        startup.write_text("import os\nopen(%r, 'w').write('hit')\n"
                           % str(canary("startup")))
        env = {"HOME": self.temp.name, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               "PYTHONPATH": str(hookdir), "PYTHONUSERBASE": str(base),
               "PYTHONSTARTUP": str(startup), "BASH_ENV": str(bash_env),
               "FOO": "poison"}
        return env, canaries

    def make_home(self, name, config=None, agent=False):
        """Isolated fake HOME, optionally with a valid config and a live fake
        socket at the production-derived path inside it."""
        home = self.root / name
        appdir = home / "Library" / "Application Support" / "pigi"
        appdir.mkdir(parents=True)
        os.chmod(appdir, 0o700)
        if config is not None:
            path = appdir / "oneshot.json"
            path.write_text(json.dumps(config))
            os.chmod(path, 0o600)
        listener = None
        if agent:
            listener = FakeAgent(str(appdir), self.table)
            listener.start()
            self.assertTrue(listener.ready.wait(3))
            self.addCleanup(listener.stop)
        return home, listener

    def invoke_main(self, argv, home, patches=()):
        """Run main() with PINNED_HOME patched to an isolated home; returns
        (exit_code, stdout_bytes, parsed_doc). Asserts stderr stays empty."""
        support = Path(home) / "Library" / "Application Support"
        python = synthetic_python()
        assert_isolated(str(home), support / "pigi" / "oneshot.json",
                        support / "pigi" / "agent.sock",
                        support / "pigi-mcp" / "audit.sqlite3",
                        interpreter=python)
        stdout, err = _BytesStdout(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(pigi_oneshot, "PINNED_HOME", str(home)))
            stack.enter_context(patch.object(pigi_oneshot, "trusted_entry", lambda: True))
            stack.enter_context(patch.object(sys, "executable", python))
            stack.enter_context(patch.object(sys, "argv", ["pigi-oneshot", *argv]))
            stack.enter_context(patch.object(sys, "stdout", stdout))
            stack.enter_context(contextlib.redirect_stderr(err))
            for extra in patches:
                stack.enter_context(extra)
            code = pigi_oneshot.main()
        self.assertEqual(err.getvalue(), "")
        out = stdout.buffer.getvalue()
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        return code, out, json.loads(out) if out else None

    def audit_rows(self):
        with sqlite3.connect(self.root / "audit.sqlite3") as db:
            return db.execute("SELECT tool,outcome FROM tool_calls ORDER BY id").fetchall()

    def methods_seen(self):
        return [request["method"] for request in self.agent.requests]

    def test_accounts_scoped_result(self):
        self.table["accounts"] = lambda params: accounts_result()
        code, out = self.invoke(["accounts"])
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["contentTrust"], "untrusted")
        self.assertEqual(doc["trustNotice"], TRUST_NOTICE)
        self.assertEqual(doc["command"], "accounts")
        self.assertEqual(doc["accounts"], [{"account": ACCOUNT, "kind": "imap"}])
        self.assertEqual(self.methods_seen(), ["accounts"])
        self.assertEqual(self.agent.requests[0]["params"], {"account": ACCOUNT})
        self.assertEqual(self.audit_rows(), [("list_accounts", "ok")])

    def test_search_argument_rejection_never_touches_socket(self):
        rejected = [["search", "--query", "x"], ["search", "x"],
                    ["search", "--since-days", "31"], ["search", "--since-days", "0"],
                    ["search", "--since-days", "x"], ["search", "--limit", "21"],
                    ["search", "--limit", "0"], ["search", "--offset", "1"],
                    ["search", "--offset=0"], ["search", "--lim", "5"],
                    ["search", "--since", "3"], ["search", "--account", "x"]]
        for argv in rejected:
            with self.subTest(argv=argv):
                code, out = self.invoke(argv)
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])

    def test_search_scopes_filters_and_reports_filtered_out(self):
        items = [make_message("m1", ALLOWED), make_message("m2", OTHER),
                 make_message("m3", ALLOWED)]
        self.table["search"] = lambda params: {**search_result(items), "nextOffset": 3}
        code, out = self.invoke(["search"])
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["command"], "search")
        self.assertEqual([item["messageID"] for item in doc["items"]], ["m1", "m3"])
        self.assertEqual(doc["filteredOut"], 1)
        self.assertNotIn("nextOffset", doc)
        request = self.agent.requests[0]
        self.assertEqual(request["method"], "search")
        self.assertEqual(request["params"], {"account": ACCOUNT, "query": "Cursor",
                                             "since": NOW - 7 * 86_400_000, "limit": 10})
        self.assertNotIn(OTHER, out.decode("utf-8"))

    def test_search_bounds(self):
        self.table["search"] = lambda params: search_result([])
        code, out = self.invoke(["search", "--since-days", "30", "--limit", "20"])
        self.assertEqual(code, 0)
        self.assertEqual(self.agent.requests[0]["params"]["since"], NOW - 30 * 86_400_000)
        self.assertEqual(self.agent.requests[0]["params"]["limit"], 20)

    def test_get_allowed_sender_returns_text(self):
        self.table["get"] = lambda params: get_result(make_message("m1"), SENTINEL)
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["command"], "get")
        self.assertEqual(doc["text"], SENTINEL)
        self.assertEqual(doc["message"]["messageID"], "m1")
        request = self.agent.requests[0]
        self.assertEqual(request["method"], "get")
        self.assertEqual(request["params"], {"account": ACCOUNT, "messageID": "m1"})

    def test_get_disallowed_sender_built_from_scratch(self):
        self.table["get"] = lambda params: get_result(
            make_message("m2", OTHER, subject="SUBJ_SENTINEL", snippet="SNIP_SENTINEL"),
            SENTINEL)
        code, out = self.invoke(["get", "m2"])
        self.assertEqual(code, 3)
        doc = self.parse(out)
        self.assertEqual(doc, {"contentTrust": "untrusted", "trustNotice": TRUST_NOTICE,
                               "allowed": False, "message": None})
        text = out.decode("utf-8")
        for leak in (SENTINEL, "SUBJ_SENTINEL", "SNIP_SENTINEL", OTHER):
            self.assertNotIn(leak, text)
        self.assertEqual(self.methods_seen(), ["get"])

    def test_get_sender_case_insensitive_match(self):
        self.table["get"] = lambda params: get_result(
            make_message("m3", "Allowed@Example.COM"), "body")
        code, out = self.invoke(["get", "m3"])
        self.assertEqual(code, 0)
        self.assertEqual(self.parse(out)["message"]["fromEmail"], "Allowed@Example.COM")

    def test_get_not_found(self):
        def responder(params):
            raise AgentError("not_found")
        self.table["get"] = responder
        code, out = self.invoke(["get", "m9"])
        self.assertEqual(code, 4)
        doc = self.parse(out)
        self.assertEqual(doc, {"contentTrust": "untrusted", "error": "not_found"})

    def test_get_invalid_ids_rejected_without_socket(self):
        for bad in ("has space", "a/b", "a<b", "a$b", "", "x" * 257):
            with self.subTest(bad=bad):
                code, out = self.invoke(["get", bad])
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
        for argv in (["get", "-abc"], ["get"], ["get", "ok", "extra"]):
            result = self.cli(argv)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])

    def test_get_batch_mixed_statuses_and_precedence(self):
        def responder(params):
            message_id = params["messageID"]
            if message_id == "gone":
                raise AgentError("not_found")
            if message_id == "boom":
                raise AgentError("timeout")
            if message_id == "deny":
                return get_result(make_message(message_id, OTHER), SENTINEL)
            return get_result(make_message(message_id), "body-" + message_id)
        self.table["get"] = responder
        code, out = self.invoke(["get-batch", "a", "deny", "gone", "boom", "b"])
        self.assertEqual(code, 5)
        doc = self.parse(out)
        self.assertEqual(doc["command"], "get-batch")
        statuses = [entry["status"] for entry in doc["results"]]
        self.assertEqual(statuses, ["ok", "filtered", "not_found", "error", "ok"])
        filtered = doc["results"][1]
        self.assertEqual(filtered, {"messageID": "deny", "status": "filtered"})
        self.assertEqual(doc["results"][3],
                         {"messageID": "boom", "status": "error", "error": "timeout"})
        self.assertNotIn(SENTINEL, out.decode("utf-8"))
        # One child, one handshake: five socket requests, five audit rows.
        self.assertEqual(self.methods_seen(), ["get"] * 5)
        self.assertEqual([row[0] for row in self.audit_rows()], ["get_message"] * 5)

    def test_get_batch_exit_code_precedence(self):
        def responder(params):
            message_id = params["messageID"]
            if message_id == "gone":
                raise AgentError("not_found")
            if message_id == "deny":
                return get_result(make_message(message_id, OTHER), SENTINEL)
            return get_result(make_message(message_id), "body")
        self.table["get"] = responder
        self.assertEqual(self.invoke(["get-batch", "a", "deny", "gone"])[0], 4)
        self.assertEqual(self.invoke(["get-batch", "a", "deny"])[0], 3)
        self.assertEqual(self.invoke(["get-batch", "a"])[0], 0)

    def test_get_batch_size_rejected_without_socket(self):
        for argv in (["get-batch"] + ["m%d" % i for i in range(6)], ["get-batch"]):
            code, out = self.invoke(argv)
            self.assertEqual(code, 2)
            self.assertEqual(self.parse(out), USAGE_DOC)
        result = self.cli(["get-batch"] + ["m%d" % i for i in range(6)])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.agent.requests, [])

    def test_unimplemented_and_scope_options_rejected(self):
        rejected = [["list"], ["get_verification_code"], ["unknown"], [],
                    ["--help"], ["-h"], ["accounts", "--help"], ["search", "-h"],
                    ["--account", "x", "accounts"], ["accounts", "--account", "x"],
                    ["--account=x", "accounts"], ["search", "extra"]]
        for argv in rejected:
            with self.subTest(argv=argv):
                code, out = self.invoke(argv)
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])
        source = SCRIPT.read_text()
        for forbidden in ('"list"', '"codes"', "get_verification_code", "list_messages"):
            self.assertNotIn(forbidden, source)

    def test_search_truncation_stays_valid_json_exit_eight(self):
        big = [make_message("m%d" % i, ALLOWED, snippet="A" * 30_000) for i in range(3)]
        self.table["search"] = lambda params: search_result(big)
        code, out = self.invoke(["search", "--limit", "20"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)  # json.loads must succeed: always valid JSON
        self.assertTrue(doc["truncated"])
        self.assertEqual(doc["contentTrust"], "untrusted")
        self.assertEqual(doc["command"], "search")
        self.assertEqual(len(doc["items"]) + doc["omittedItems"], 3)
        self.assertGreater(doc["omittedItems"], 0)
        self.assertEqual(doc["filteredOut"], 0)

    def test_get_truncation_multibyte_text_exit_eight(self):
        message = make_message("m1")
        text = "中文字符正文🎉trailer" * 6_000
        self.table["get"] = lambda params: get_result(message, text)
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertTrue(doc["textTruncated"])
        self.assertEqual(doc["message"]["messageID"], "m1")
        self.assertLess(len(doc["text"]), len(text))
        full = pigi_oneshot.envelope("get", {"message": message, "text": text})
        self.assertEqual(doc["originalBytes"], len(pigi_oneshot.serialize(full)))

    def test_get_batch_truncation_cuts_every_text(self):
        texts = {"m%d" % i: "B" * 30_000 + str(i) for i in range(5)}
        self.table["get"] = lambda params: get_result(
            make_message(params["messageID"]), texts[params["messageID"]])
        code, out = self.invoke(["get-batch"] + list(texts))
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertEqual(len(doc["results"]), 5)
        for entry in doc["results"]:
            self.assertEqual(entry["status"], "ok")
            self.assertTrue(entry["textTruncated"])

    def test_get_batch_truncation_keeps_denial_exit_three(self):
        def responder(params):
            message_id = params["messageID"]
            if message_id == "deny":
                return get_result(make_message(message_id, OTHER), SENTINEL)
            return get_result(make_message(message_id), "B" * 40_000)
        self.table["get"] = responder
        code, out = self.invoke(["get-batch", "a", "deny", "c"])
        self.assertEqual(code, 3)  # already non-zero: truncation does not lift it to 8
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertEqual(doc["results"][1], {"messageID": "deny", "status": "filtered"})
        self.assertNotIn(SENTINEL, out.decode("utf-8"))

    def test_truncation_fallback_when_metadata_alone_huge(self):
        giant = make_message("m1", subject="S" * 200_000)
        self.table["get"] = lambda params: get_result(giant, SENTINEL)
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 8)
        doc = self.parse(out)
        self.assertEqual(set(doc), {"contentTrust", "trustNotice", "command",
                                    "truncated", "truncationNotice", "originalBytes"})
        self.assertEqual(doc["command"], "get")
        self.assertTrue(doc["truncated"])
        for leak in (SENTINEL, "S" * 100):
            self.assertNotIn(leak, out.decode("utf-8"))

    def test_serialized_boundary_exactly_max_stdout(self):
        message = make_message("m1")
        overhead = len(pigi_oneshot.serialize(
            pigi_oneshot.envelope("get", {"message": message, "text": ""})))
        self.table["get"] = lambda params: get_result(
            message, "x" * (pigi_oneshot.MAX_STDOUT - overhead))
        code, out = self.invoke(["get", "m1"])
        self.assertEqual((code, len(out)), (0, pigi_oneshot.MAX_STDOUT))
        self.assertNotIn("truncated", self.parse(out))
        self.table["get"] = lambda params: get_result(
            message, "x" * (pigi_oneshot.MAX_STDOUT + 1 - overhead))
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        self.assertTrue(self.parse(out)["truncated"])

    def test_preamble_gate_precedes_environment_imports(self):
        import ast
        tree = ast.parse(SCRIPT.read_text())
        gate = None
        for node in tree.body:
            if (isinstance(node, ast.If) and isinstance(node.test, ast.BoolOp)
                    and any(isinstance(part, ast.Compare)
                            and isinstance(part.left, ast.Name)
                            and part.left.id == "__name__" for part in node.test.values)):
                gate = node
                break
        self.assertIsNotNone(gate, "missing __main__ trusted-entry gate")
        before = tree.body[:tree.body.index(gate)]
        defined = {node.name for node in before if isinstance(node, ast.FunctionDef)}
        self.assertIn("trusted_entry", defined)
        for node in before:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    self.assertIn(alias.name, {"os", "sys"})
            elif isinstance(node, ast.ImportFrom):
                self.fail("module import before trusted-entry gate: %s" % node.module)
        self.assertTrue(any(isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                            and n.func.attr == "exit" for n in ast.walk(gate)))

    def test_direct_launch_refused_exit_nine(self):
        env, canaries = self.make_hooks()
        result = self.run_python([synthetic_python(), str(SCRIPT), "list"],
                                capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stdout,
                         b'{"contentTrust":"untrusted","error":"untrusted_entry"}')
        self.assertEqual(result.stderr, b"")
        # Site hooks may already have run — the documented pre-first-line limit —
        # but the refusal happens before parse/config/socket.
        self.assertTrue(canaries["sitecustomize"].exists())
        self.assertEqual(self.agent.requests, [])

    def test_direct_launch_gate_variants(self):
        env, _ = self.make_hooks()
        # Launcher flag set but interpreter not isolated -> still refused.
        flagged = dict(env)
        flagged[pigi_oneshot.TRUSTED_FLAG_NAME] = pigi_oneshot.TRUSTED_FLAG_VALUE
        result = self.run_python([synthetic_python(), str(SCRIPT), "list"],
                                capture_output=True, timeout=20, env=flagged)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stderr, b"")
        # Isolation flags but no launcher flag -> refused.
        result = self.run_python(
            [synthetic_python(), "-I", "-S", "-B", "-X", "utf8", str(SCRIPT), "list"],
            capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stderr, b"")
        # Flag plus all isolation flags -> passes the gate, rejects `list`.
        result = self.run_python(
            [synthetic_python(), "-I", "-S", "-B", "-X", "utf8", str(SCRIPT), "list"],
            capture_output=True, timeout=20, env=flagged)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(result.stderr, b"")

    def test_launcher_blocks_environment_hooks(self):
        home, _ = self.make_home("hla")
        launcher = self.render_launcher(self.root, synthetic_python(), SCRIPT, home)
        env, canaries = self.make_hooks()
        for argv in (["list"], ["--account", "x"]):
            with self.subTest(argv=argv):
                result = subprocess.run([str(launcher), *argv],
                                        capture_output=True, timeout=20, env=env)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
                self.assertEqual(result.stderr, b"")
        for name, path in canaries.items():
            self.assertFalse(path.exists(), name)

    def test_launcher_child_environment_fixed_and_args_verbatim(self):
        home, _ = self.make_home("hpr")
        probe = self.root / "probe.py"
        probe.write_text(
            "import json, os, sys\n"
            "sys.stdout.write(json.dumps({\n"
            "    'env': dict(os.environ),\n"
            "    'flags': {'isolated': bool(sys.flags.isolated),\n"
            "              'no_site': bool(sys.flags.no_site),\n"
            "              'dont_write_bytecode': bool(sys.flags.dont_write_bytecode),\n"
            "              'utf8_mode': bool(sys.flags.utf8_mode)},\n"
            "    'argv': sys.argv[1:]}))\n")
        launcher = self.render_launcher(self.root, synthetic_python(), probe, home)
        env, _ = self.make_hooks()
        args = ["a b", "qu'ote", "$HOME", "a;b", 'x"y']
        result = subprocess.run([str(launcher), *args],
                                capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        doc = json.loads(result.stdout)
        # macOS libSystem synthesizes __CF_USER_TEXT_ENCODING inside the new
        # process after exec; it is OS-injected, not inherited — env -i cannot
        # remove it. Everything else must be exactly the launcher whitelist.
        keys = set(doc["env"]) - {"__CF_USER_TEXT_ENCODING"}
        self.assertEqual(keys,
                         {"HOME", "PATH", "LANG", "LC_ALL", "PIGI_ONESHOT_LAUNCHER"})
        for poison in ("PYTHONPATH", "PYTHONUSERBASE", "PYTHONSTARTUP",
                       "PYTHONHOME", "BASH_ENV", "FOO"):
            self.assertNotIn(poison, doc["env"])
        self.assertEqual(doc["env"]["HOME"], str(home))
        self.assertEqual(doc["env"]["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(doc["env"]["PIGI_ONESHOT_LAUNCHER"], "trusted-entry-v1")
        self.assertEqual(doc["flags"], {"isolated": True, "no_site": True,
                                        "dont_write_bytecode": True,
                                        "utf8_mode": True})
        self.assertEqual(doc["argv"], args)

    def test_launcher_fails_closed(self):
        home, _ = self.make_home("hcl")
        d1, d2 = self.root / "r1", self.root / "r2"
        d1.mkdir()
        d2.mkdir()
        launcher = self.render_launcher(d1, self.root / "no-such-python",
                                        SCRIPT, home)
        merged, split = self.launch(launcher, ["accounts"])
        self.assert_json_contract(merged, split, 6, CONFIG_DOC)
        launcher = self.render_launcher(d2, synthetic_python(),
                                        self.root / "no-such-script.py", home)
        merged, split = self.launch(launcher, ["accounts"])
        self.assert_json_contract(merged, split, 6, CONFIG_DOC)

    def test_launcher_normalizes_interpreter_failures(self):
        home, _ = self.make_home("hni")

        def render(python, script=SCRIPT, tag="r"):
            sub = tempfile.mkdtemp(prefix=tag + "-", dir=self.temp.name)
            return self.render_launcher(sub, python, script, home)

        # (a) a corrupted-but-executable binary: native magic prefix with no
        # real program behind it — passes the guard's native-binary rule, then
        # exec itself fails (126/127) -> exit 6.
        stub = self.root / "macho-stub"
        stub.write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 60)
        os.chmod(stub, 0o755)
        merged, split = self.launch(render(stub, tag="a"), ["accounts"])
        self.assert_json_contract(merged, split, 6, CONFIG_DOC)

        # (b) a real interpreter whose run exits 127 -> exit 6.
        exit127 = self.root / "exit127.py"
        exit127.write_text("import sys; sys.exit(127)\n")
        merged, split = self.launch(
            render(synthetic_python(), exit127, tag="b"), ["accounts"])
        self.assert_json_contract(merged, split, 6, CONFIG_DOC)

        # (c) the interpreter writes junk to stdout+stderr then dies on a
        # signal -> exit 7, captured junk never surfaces.
        crash = self.root / "crash.py"
        crash.write_text(
            "import os, sys\n"
            "sys.stdout.write('JUNK-OUT'); sys.stdout.flush()\n"
            "sys.stderr.write('JUNK-ERR'); sys.stderr.flush()\n"
            "os.kill(os.getpid(), 11)\n")
        merged, split = self.launch(
            render(synthetic_python(), crash, tag="c"), ["accounts"])
        self.assert_json_contract(merged, split, 7, INTERNAL_DOC)
        self.assertNotIn(b"JUNK", merged.stdout)
        self.assertNotIn(b"JUNK", split.stdout)

    def test_launcher_passthrough_status_and_args(self):
        home, _ = self.make_home("hpt")
        exiter = self.root / "exiter.py"
        exiter.write_text(
            "import json, sys\n"
            "sys.stdout.write(json.dumps({'contentTrust': 'untrusted',"
            " 'argv': sys.argv[1:]}))\n"
            "sys.exit(int(sys.argv[1]))\n")
        sub = self.root / "rpt"
        sub.mkdir()
        launcher = self.render_launcher(sub, synthetic_python(), exiter, home)
        for code in (0, 2, 9):
            merged, split = self.launch(launcher, [str(code), "arg with spaces"])
            self.assertEqual(split.returncode, code)
            self.assertEqual(split.stderr, b"")
            doc = json.loads(split.stdout)
            self.assertEqual(doc["contentTrust"], "untrusted")
            self.assertEqual(doc["argv"], [str(code), "arg with spaces"])
            self.assertEqual(json.loads(merged.stdout), doc)

    def test_bash_env_never_runs_on_supported_launches(self):
        home, _ = self.make_home("hba")
        launcher = self.render_launcher(self.root, synthetic_python(), SCRIPT, home)
        env, canaries = self.make_hooks()
        for command in ([str(launcher), "list"], ["/bin/sh", str(launcher), "list"]):
            with self.subTest(command=command):
                self.assertFalse(canaries["bash_env"].exists())
                result = subprocess.run(command, capture_output=True,
                                        timeout=20, env=env)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
                self.assertEqual(result.stderr, b"")
                self.assertFalse(canaries["bash_env"].exists())

    @unittest.skipUnless(os.path.exists("/bin/bash"), "no /bin/bash available")
    def test_bash_wrapper_runs_bash_env_hazard(self):
        # Documents why `bash pigi_oneshot.sh` is forbidden: bash sources
        # $BASH_ENV before the script's first line — the canary fires even
        # though the run itself still ends in the fixed refusal.
        home, _ = self.make_home("hbb")
        launcher = self.render_launcher(self.root, synthetic_python(), SCRIPT, home)
        env, canaries = self.make_hooks()
        result = subprocess.run(["/bin/bash", str(launcher), "list"],
                                capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertTrue(canaries["bash_env"].exists())

    def test_launcher_source_and_mode(self):
        self.assertTrue(os.access(LAUNCHER, os.X_OK))
        listing = subprocess.run(
            ["git", "ls-files", "-s", "tools/pigi-mcp/pigi_oneshot.sh"],
            capture_output=True, text=True, cwd=REPO_ROOT).stdout
        if listing.strip():  # indexed in this checkout
            self.assertTrue(listing.startswith("100755"), listing)
        source = LAUNCHER.read_text()
        self.assertNotIn("eval", source)
        self.assertNotIn("SSH_ORIGINAL_COMMAND", source)
        self.assertIn("env -i", source)
        self.assertIn("-I -S -B", source)
        self.assertIn("umask 077", source)
        self.assertNotIn("execve", SCRIPT.read_text())

    def test_get_batch_all_denied_exact_filtered_shape(self):
        self.table["get"] = lambda params: get_result(
            make_message(params["messageID"], OTHER, subject="SUBJ_SENTINEL",
                         snippet="SNIP_SENTINEL"), SENTINEL)
        code, out = self.invoke(["get-batch", "a", "b", "c"])
        self.assertEqual(code, 3)
        doc = self.parse(out)
        self.assertEqual(doc["results"], [{"messageID": mid, "status": "filtered"}
                                          for mid in ("a", "b", "c")])
        text = out.decode("utf-8")
        for leak in (SENTINEL, "SUBJ_SENTINEL", "SNIP_SENTINEL", OTHER):
            self.assertNotIn(leak, text)

    def test_get_writes_exactly_one_adapter_audit_row(self):
        self.table["get"] = lambda params: get_result(make_message("m1"), "body")
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 0)
        self.assertEqual(self.audit_rows(), [("get_message", "ok")])

    def test_docs_contract_matches_implementation(self):
        doc = DOCS.read_text()
        self.assertIn('"status":"filtered"', doc)
        self.assertNotIn("no write path", doc)
        self.assertIn("tool_calls", doc)
        self.assertIn("| 8 |", doc)
        self.assertIn("truncated", doc)
        self.assertIn('"error":"invalid_arguments"', doc)
        self.assertIn('"error":"configuration_unavailable"', doc)
        self.assertIn('"error":"internal_error"', doc)
        self.assertIn('"error":"untrusted_entry"', doc)
        self.assertIn("| 9 |", doc)
        self.assertIn("stderr", doc)

    def test_docs_forbidden_wrappers_and_normalized_rows(self):
        doc = DOCS.read_text()
        self.assertIn("BASH_ENV", doc)
        self.assertIn("bash pigi_oneshot.sh", doc)
        # The bash-wrapper ban must be stated as forbidden/not supported.
        self.assertRegex(doc,
                         r"(?s)bash pigi_oneshot\.sh.{0,200}forbidden|"
                         r"forbidden.{0,200}bash pigi_oneshot\.sh|"
                         r"bash pigi_oneshot\.sh.{0,200}not supported|"
                         r"not supported.{0,200}bash pigi_oneshot\.sh")
        self.assertIn("directly", doc)
        # Updated exit-table wording for launcher normalization.
        self.assertIn("126/127", doc)
        self.assertIn("normalized", doc)
        self.assertIn("does not `exec`", doc)

    def test_config_loader_fails_closed(self):
        home = self.root / "cfg-home"
        config_dir = home / "Library" / "Application Support" / "pigi"
        config_path = config_dir / "oneshot.json"

        def expect_six():
            with self.assertRaises(pigi_oneshot.ConfigError):
                pigi_oneshot.load_config(str(home))

        expect_six()  # missing entirely
        config_dir.mkdir(parents=True, mode=0o700)
        config_path.write_text('{"account": "%s", "senders": ["%s"]}' % (ACCOUNT, ALLOWED))
        os.chmod(config_path, 0o644)
        expect_six()  # permissive mode
        os.chmod(config_path, 0o600)
        link = config_dir / "link.json"
        os.link(config_path, link)
        expect_six()  # hard link count != 1 — still fail closed via the real path
        link.unlink()
        # Symlink in place of the config file.
        config_path.unlink()
        config_path.symlink_to(home)
        expect_six()
        config_path.unlink()
        # Wrong shapes.
        for doc in [{}, {"account": ACCOUNT}, {"senders": [ALLOWED]},
                    {"account": ACCOUNT, "senders": []},
                    {"account": ACCOUNT, "senders": [ALLOWED], "extra": 1},
                    {"account": "  ", "senders": [ALLOWED]},
                    {"account": ACCOUNT, "senders": ["  "]},
                    {"account": ACCOUNT, "senders": "notalist"},
                    {"account": 5, "senders": [ALLOWED]},
                    {"account": "x" * 1025, "senders": [ALLOWED]}]:
            config_path.write_text(json.dumps(doc))
            os.chmod(config_path, 0o600)
            expect_six()
        config_path.write_text("not json")
        os.chmod(config_path, 0o600)
        expect_six()
        # Group/world-writable parent dir.
        os.chmod(config_dir, 0o777)
        expect_six()
        os.chmod(config_dir, 0o700)
        # Valid.
        config_path.write_text('{"account": "%s", "senders": [" %s ", "%s"]}'
                               % (ACCOUNT, ALLOWED.upper(), OTHER))
        os.chmod(config_path, 0o600)
        config = pigi_oneshot.load_config(str(home))
        self.assertEqual(config["account"], ACCOUNT)
        self.assertEqual(config["senders"], frozenset({ALLOWED, OTHER}))

    def test_trusted_entry_gate(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(pigi_oneshot.trusted_entry())
        # The flag alone is not enough: this test process is not isolated.
        with patch.dict(os.environ, {pigi_oneshot.TRUSTED_FLAG_NAME:
                                     pigi_oneshot.TRUSTED_FLAG_VALUE},
                        clear=True):
            self.assertFalse(pigi_oneshot.trusted_entry())
        self.assertEqual(pigi_oneshot.TRUSTED_FLAG_NAME, "PIGI_ONESHOT_LAUNCHER")
        self.assertEqual(pigi_oneshot.TRUSTED_FLAG_VALUE, "trusted-entry-v1")
        self.assertEqual(pigi_oneshot.EXIT_UNTRUSTED_ENTRY, 9)

    def test_transport_failures_exit_five_without_leaks(self):
        self.table["accounts"] = lambda params: accounts_result()
        missing = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=self.root / "missing.sock",
            audit_db=self.root / "a2.sqlite3", python=synthetic_python(),
            home=self.temp.name, now_ms=lambda: NOW)
        code, out = self.invoke(["accounts"], missing)
        self.assertEqual(code, 5)
        doc = self.parse(out)
        self.assertEqual(doc["contentTrust"], "untrusted")
        self.assertIn(doc["error"], FIXED_ERROR_CODES)
        # A regular file at the socket path yields the same fixed-shape error.
        regular = self.root / "not-a-socket"
        regular.write_text("keep")
        bad = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=regular, audit_db=self.root / "a3.sqlite3",
            python=synthetic_python(), home=self.temp.name, now_ms=lambda: NOW)
        code, out = self.invoke(["accounts"], bad)
        self.assertEqual(code, 5)
        self.assertNotIn(SENTINEL, out.decode("utf-8"))

    def test_internal_error_exit_seven(self):
        with patch.object(pigi_oneshot, "mcp_session", side_effect=RuntimeError("boom")):
            code, out = self.invoke(["accounts"])
        self.assertEqual(code, 7)
        self.assertEqual(self.parse(out), INTERNAL_DOC)

    def test_only_scoped_methods_ever_called(self):
        self.table["accounts"] = lambda params: accounts_result()
        self.table["search"] = lambda params: search_result([make_message("m1")])
        self.table["get"] = lambda params: get_result(make_message("m1"), "body")
        for argv in (["accounts"], ["search"], ["get", "m1"],
                     ["get-batch", "m1", "m2"]):
            self.invoke(argv)
        for request in self.agent.requests:
            self.assertIn(request["method"], {"accounts", "search", "get"})
            self.assertEqual(request["params"]["account"], ACCOUNT)

    def test_no_real_addresses_or_default_socket(self):
        self.assertNotEqual(str(self.ctx.socket_path), str(transport.DEFAULT_SOCKET))
        self.assertTrue(str(self.ctx.socket_path).startswith(self.temp.name))
        domains = {"example.com", "example.org", "example.net"}
        pattern = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
        for path in (SCRIPT, FULL_SCRIPT, LAUNCHER, Path(__file__), DOCS):
            self.assertTrue(path.exists(), path)
            for match in pattern.finditer(path.read_text()):
                self.assertIn(match.group(1).lower(), domains, (path, match.group(0)))

    def test_source_has_no_stderr_usage(self):
        source = SCRIPT.read_text()
        self.assertNotIn("sys.stderr", source)
        self.assertNotIn("file=sys.stderr", source)

    def test_cli_stderr_empty_stdout_single_json(self):
        cases = [["bogus"], ["list"], ["get_verification_code"], ["--account", "x"],
                 ["--account=x", "accounts"], ["search", "--limit", "21"],
                 ["search", "--since-days", "0"], ["get", "bad id"], ["get", "a/b"],
                 ["--help"], ["-h"], [], ["accounts", "--help"],
                 ["get-batch"] + ["i%d" % i for i in range(6)]]
        for argv in cases:
            with self.subTest(argv=argv):
                merged = self.run_python(
                    [synthetic_python(), "-I", "-S", "-B", "-X", "utf8", str(SCRIPT), *argv],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
                    env=self.trusted_env())
                self.assertEqual(merged.returncode, 2)
                # stdout+stderr merged is still exactly the one JSON document.
                self.assertEqual(json.loads(merged.stdout), USAGE_DOC)
                self.assertLessEqual(len(merged.stdout), pigi_oneshot.MAX_STDOUT)
                split = self.cli(argv)  # asserts stderr == b"" itself
                self.assertEqual(split.returncode, 2)
                self.assertEqual(json.loads(split.stdout + split.stderr), USAGE_DOC)

    def test_child_stderr_is_discarded_never_forwarded(self):
        # The child writes "transport or audit unavailable." on ITS stderr when
        # the audit DB path cannot be created; our stderr must stay empty and
        # stdout the fixed exit-5 JSON.
        blocker = self.root / "blocker"
        blocker.write_text("not a dir")
        ctx = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=self.agent.endpoint,
            audit_db=blocker / "audit.sqlite3", python=synthetic_python(),
            home=self.temp.name, now_ms=lambda: NOW)
        self.table["accounts"] = lambda params: accounts_result()
        code, out = self.invoke(["accounts"], ctx)  # invoke asserts stderr == ""
        self.assertEqual(code, 5)
        self.assertEqual(self.parse(out)["error"], "upstream_unavailable")
        self.assertEqual(self.agent.requests, [])

    def test_isolation_guard(self):
        home = self.root / "guard-home"
        home.mkdir()
        config = home / "oneshot.json"
        sock_dir = self.root / "guard-sock"
        sock_dir.mkdir()
        sock = sock_dir / "agent.sock"
        audit_path = self.root / "guard-audit.sqlite3"
        assert_isolated(str(home), str(config), str(sock), str(audit_path))
        for bad_home in (os.path.expanduser("~"),
                         pwd.getpwuid(os.getuid()).pw_dir, ORIGINAL_PINNED_HOME):
            with self.subTest(home=bad_home):
                with self.assertRaises(AssertionError):
                    assert_isolated(bad_home, str(config), str(sock), str(audit_path))
        real_home = os.path.expanduser("~")
        support = Path(real_home) / "Library" / "Application Support"
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(config),
                            str(support / "pigi" / "agent.sock"), str(audit_path))
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(config),
                            str(transport.DEFAULT_SOCKET), str(audit_path))
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(config), str(sock),
                            str(audit.DEFAULT_AUDIT))
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(support / "pigi" / "oneshot.json"),
                            str(sock), str(audit_path))
        # A synthetic path merely under the real home is allowed — the guard
        # compares path strings only, nothing is created or touched there.
        under = os.path.join(os.path.realpath(real_home),
                             "synthetic-not-protected-dir")
        assert_isolated(under, under + "/oneshot.json", under + "/agent.sock",
                        under + "/audit.sqlite3")

    def test_interpreter_guard(self):
        home = self.root / "ig"
        home.mkdir()
        paths = [str(home / "oneshot.json"), str(home / "agent.sock"),
                 str(home / "audit.sqlite3")]
        assert_isolated(str(home), *paths, interpreter=synthetic_python())
        pinned = PINNED_LAUNCHER_PYTHON
        variants = {pinned, os.path.realpath(pinned),
                    os.path.normpath(pinned).replace(
                        "/bin/python3", "/bin/../bin/python3")}
        for bad in variants:
            with self.subTest(interpreter=bad):
                with self.assertRaises(AssertionError):
                    assert_isolated(str(home), *paths, interpreter=bad)
        # render_launcher refuses the real interpreter before writing anything.
        outdir = self.root / "render-deny"
        outdir.mkdir()
        with self.assertRaises(AssertionError):
            self.render_launcher(outdir, pinned, SCRIPT, home)
        self.assertEqual(list(outdir.iterdir()), [])
        # The spawn helper refuses before Popen is ever invoked.
        with patch.object(subprocess, "run") as mock_run:
            with self.assertRaises(AssertionError):
                self.run_python([pinned, "--version"])
        mock_run.assert_not_called()

    def test_validate_test_interpreter_rejects_wrappers(self):
        pinned_real = os.path.realpath(PINNED_LAUNCHER_PYTHON)
        # A shim that merely execs the real binary is not an interpreter.
        shim = self.root / "shim"
        shim.write_text("#!/bin/sh\nexec '%s' \"$@\"\n" % pinned_real)
        os.chmod(shim, 0o755)
        with self.assertRaises(AssertionError):
            validate_test_interpreter(str(shim))
        # The guard blocks it before a launcher is rendered or a spawn runs.
        outdir = self.root / "no-render"
        outdir.mkdir()
        home = self.root / "shim-home"
        home.mkdir()
        with self.assertRaises(AssertionError):
            self.render_launcher(outdir, shim, SCRIPT, home)
        self.assertEqual(list(outdir.iterdir()), [])
        with patch.object(subprocess, "run") as mock_run:
            with self.assertRaises(AssertionError):
                self.run_python([str(shim), "--version"])
        mock_run.assert_not_called()
        # A symlink to the pinned binary fails the realpath rule.
        link = self.root / "python-link"
        link.symlink_to(pinned_real)
        with self.assertRaises(AssertionError):
            validate_test_interpreter(str(link))
        # Missing or non-executable candidates fail statically.
        with self.assertRaises(AssertionError):
            validate_test_interpreter(str(self.root / "absent"))
        plain = self.root / "plain"
        plain.write_text("")
        os.chmod(plain, 0o644)
        with self.assertRaises(AssertionError):
            validate_test_interpreter(str(plain))

    def test_synthetic_python_result_is_native_nonproduction(self):
        chosen = synthetic_python()
        self.assertEqual(validate_test_interpreter(chosen), chosen)
        self.assertNotEqual(os.path.realpath(chosen),
                            os.path.realpath(PINNED_LAUNCHER_PYTHON))
        with open(chosen, "rb") as handle:
            self.assertNotEqual(handle.read(2), b"#!")

    def test_synthetic_python_fails_closed(self):
        pinned = PINNED_LAUNCHER_PYTHON
        link = self.root / "cand-link"
        link.symlink_to(os.path.realpath(pinned))
        shim = self.root / "cand-shim"
        shim.write_text("#!/bin/sh\nexec '%s' \"$@\"\n"
                        % os.path.realpath(pinned))
        os.chmod(shim, 0o755)
        module = sys.modules[__name__]
        env = {k: v for k, v in os.environ.items()
               if k != "PIGI_TEST_PYTHON"}
        before = set(os.listdir(self.temp.name))
        with patch.object(module, "_SYNTHETIC_PYTHON", None), \
                patch.dict(os.environ, env, clear=True), \
                patch.object(sys, "executable", pinned), \
                patch.object(module, "TEST_PYTHON_CANDIDATES",
                             (str(link), str(shim))), \
                patch.object(tempfile, "mkdtemp") as mock_mkdtemp:
            with self.assertRaises(AssertionError):
                synthetic_python()
        mock_mkdtemp.assert_not_called()
        self.assertEqual(set(os.listdir(self.temp.name)), before)

    def test_pigi_test_python_override_fails_closed(self):
        module = sys.modules[__name__]
        shim = self.root / "env-shim"
        shim.write_text("#!/bin/sh\nexec '%s' \"$@\"\n"
                        % os.path.realpath(PINNED_LAUNCHER_PYTHON))
        os.chmod(shim, 0o755)
        for bad in (PINNED_LAUNCHER_PYTHON, str(shim)):
            with self.subTest(bad=bad), \
                    patch.object(module, "_SYNTHETIC_PYTHON", None), \
                    patch.dict(os.environ, {"PIGI_TEST_PYTHON": bad}):
                with self.assertRaises(AssertionError):
                    synthetic_python()

    def test_fixture_socket_paths_stay_short(self):
        # AF_UNIX sun_path is 104 bytes on macOS; a long TMPDIR must surface as
        # a clear failure here, not an obscure bind error in a fixture.
        self.assertLessEqual(len(os.fsencode(str(self.ctx.socket_path))), 100)
        longest = (self.root / "00000000" / "Library" / "Application Support"
                   / "pigi" / "agent.sock")
        self.assertLessEqual(len(os.fsencode(str(longest))), 100)

    def test_main_harness_refuses_real_home(self):
        with patch.object(pigi_oneshot, "main") as mock_main:
            with self.assertRaises(AssertionError):
                self.invoke_main(["accounts"], ORIGINAL_PINNED_HOME)
        mock_main.assert_not_called()

    def test_main_contract_end_to_end(self):
        valid = {"account": ACCOUNT, "senders": [ALLOWED]}

        home, _ = self.make_home("h6a")  # no config file
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual((code, doc), (6, CONFIG_DOC))

        home, _ = self.make_home("h6b")
        unsafe = home / "Library" / "Application Support" / "pigi" / "oneshot.json"
        unsafe.write_text(json.dumps(valid))
        os.chmod(unsafe, 0o644)
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual((code, doc), (6, CONFIG_DOC))

        for argv in (["bogus"], ["--help"],
                     ["get-batch"] + ["i%d" % i for i in range(6)]):
            code, _, doc = self.invoke_main(argv, home)
            self.assertEqual((code, doc), (2, USAGE_DOC))

        home, _ = self.make_home("h7", valid)
        boom = patch.object(pigi_oneshot, "run_command",
                            side_effect=RuntimeError("boom"))
        code, _, doc = self.invoke_main(["accounts"], home, patches=(boom,))
        self.assertEqual((code, doc), (7, INTERNAL_DOC))

        home, _ = self.make_home("h5", valid)  # config ok, socket missing
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual(code, 5)
        self.assertIn(doc["error"], FIXED_ERROR_CODES)

        home, _ = self.make_home("h0", valid, agent=True)
        self.table["accounts"] = lambda params: accounts_result()
        code, out, doc = self.invoke_main(["accounts"], home)
        self.assertEqual(code, 0)
        self.assertEqual(doc["command"], "accounts")
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)

        self.table["get"] = lambda params: get_result(
            make_message(params["messageID"], OTHER), SENTINEL)
        code, out, doc = self.invoke_main(["get", "m1"], home)
        self.assertEqual((code, doc["allowed"]), (3, False))
        self.assertNotIn(SENTINEL, out.decode("utf-8"))
        code, _, doc = self.invoke_main(["get-batch", "a", "b"], home)
        self.assertEqual(code, 3)
        self.assertEqual(doc["results"], [{"messageID": "a", "status": "filtered"},
                                          {"messageID": "b", "status": "filtered"}])

        def gone(params):
            raise AgentError("not_found")
        self.table["get"] = gone
        code, _, doc = self.invoke_main(["get", "m9"], home)
        self.assertEqual((code, doc), (4, {"contentTrust": "untrusted",
                                           "error": "not_found"}))

        self.table["get"] = lambda params: get_result(make_message("m1"), "x" * 100_000)
        code, out, doc = self.invoke_main(["get", "m1"], home)
        self.assertEqual((code, doc["truncated"]), (8, True))
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)

    def full_ctx(self):
        return pigi_oneshot.Context(
            FULL_ACCOUNT, (), socket_path=self.agent.endpoint,
            audit_db=self.root / "audit.sqlite3", python=synthetic_python(),
            home=self.temp.name, now_ms=lambda: NOW, profile="full")

    def invoke_full(self, argv, ctx=None):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code, out = pigi_oneshot_full.execute(argv, ctx or self.full_ctx())
        self.assertEqual(err.getvalue(), "")
        return code, out

    def write_profile_config(self, home, name, doc, mode=0o600):
        path = Path(home) / "Library" / "Application Support" / "pigi" / name
        path.write_text(json.dumps(doc))
        os.chmod(path, mode)
        return path

    def test_profile_token_is_argv_only(self):
        self.assertEqual(pigi_oneshot.select_profile(["search"]),
                         ("billing", ["search"]))
        self.assertEqual(pigi_oneshot.select_profile(["billing", "search"]),
                         ("billing", ["search"]))
        self.assertEqual(pigi_oneshot.select_profile(["full", "list"]),
                         ("full", ["list"]))
        self.assertEqual(pigi_oneshot.select_profile(["FULL", "list"]),
                         ("billing", ["FULL", "list"]))
        self.assertEqual(pigi_oneshot.select_profile([]), ("billing", []))
        billing = {"account": ACCOUNT, "senders": [ALLOWED]}
        home, listener = self.make_home("sel", billing, agent=True)
        self.write_profile_config(home, "oneshot-full.json", {"account": FULL_ACCOUNT})
        marker = home / "Library" / "Application Support" / "pigi" / "profile.json"
        marker.write_text('{"profile": "full"}')
        os.chmod(marker, 0o666)

        def accounts(params):
            return {"accounts": [{"account": params["account"], "kind": "imap"}],
                    "contentTrust": "untrusted", "capabilities": CAPS}

        self.table["accounts"] = accounts
        self.table["search"] = lambda params: search_result([])
        with patch.dict(os.environ, {"PIGI_ONESHOT_PROFILE": "full",
                                     "PIGI_PROFILE": "full"}):
            code, _, doc = self.invoke_main(["accounts"], home)
            self.assertEqual(code, 0)
            self.assertEqual(listener.requests[-1]["params"]["account"], ACCOUNT)
            code, _, _ = self.invoke_main(["search"], home)
            self.assertEqual(code, 0)
            self.assertEqual(listener.requests[-1]["params"]["account"], ACCOUNT)
            self.assertEqual(listener.requests[-1]["params"]["query"], "Cursor")
            code, _, doc = self.invoke_main(["billing", "accounts"], home)
            self.assertEqual(code, 0)
            self.assertEqual(doc["accounts"], [{"account": ACCOUNT, "kind": "imap"}])
            self.assertEqual(listener.requests[-1]["params"]["account"], ACCOUNT)
            code, _, doc = self.invoke_main(["full", "accounts"], home)
            self.assertEqual(code, 0)
            self.assertEqual(doc["accounts"], [{"account": FULL_ACCOUNT, "kind": "imap"}])
            self.assertEqual(listener.requests[-1]["params"]["account"], FULL_ACCOUNT)
            self.assertNotIn(ACCOUNT, json.dumps(doc))
        self.assertEqual(self.agent.requests, [])

    def test_billing_command_line_still_rejects_list(self):
        for argv in (["list"], ["billing", "list"], ["full"],
                     ["full", "get_verification_code"], ["no-such", "accounts"]):
            with self.subTest(argv=argv):
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])

    def test_billing_get_full_is_a_message_id(self):
        self.table["get"] = lambda params: get_result(make_message("full"), "body")
        code, out = self.invoke(["get", "full"])
        self.assertEqual(code, 0)
        self.assertEqual(self.parse(out)["text"], "body")
        self.assertEqual(self.agent.requests[0]["params"],
                         {"account": ACCOUNT, "messageID": "full"})

    def test_full_commands_on_fake_socket(self):
        ctx = self.full_ctx()

        def own(message_id, sender=OTHER):
            return make_message(message_id, sender, account=FULL_ACCOUNT)

        self.table["accounts"] = lambda params: {
            "accounts": [{"account": params["account"], "kind": "imap"}],
            "contentTrust": "untrusted", "capabilities": CAPS}
        code, out = self.invoke_full(["accounts"], ctx)
        self.assertEqual(code, 0)
        self.assertEqual(self.parse(out)["accounts"],
                         [{"account": FULL_ACCOUNT, "kind": "imap"}])
        self.assertEqual(self.agent.requests[-1]["params"]["account"], FULL_ACCOUNT)

        self.table["list"] = lambda params: search_result([own("m1")])
        code, out = self.invoke_full(["list"], ctx)
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["command"], "list")
        self.assertEqual(doc["items"][0]["fromEmail"], OTHER)
        self.assertNotIn("filteredOut", doc)
        params = self.agent.requests[-1]["params"]
        self.assertEqual(params, {"account": FULL_ACCOUNT,
                                  "since": NOW - 7 * 86_400_000, "limit": 10})
        code, out = self.invoke_full(["list", "--since-days", "30", "--limit", "20"], ctx)
        self.assertEqual(code, 0)
        self.assertEqual(self.agent.requests[-1]["params"]["limit"], 20)
        self.assertEqual(self.agent.requests[-1]["params"]["since"], NOW - 30 * 86_400_000)
        self.assertNotIn("offset", self.agent.requests[-1]["params"])

        self.table["search"] = lambda params: search_result([own("m2")])
        code, out = self.invoke_full(["search", "--query", "发票 hello"], ctx)
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["items"][0]["messageID"], "m2")
        self.assertNotIn("filteredOut", doc)
        self.assertIn(OTHER, out.decode("utf-8"))
        self.assertEqual(self.agent.requests[-1]["params"]["query"], "发票 hello")
        self.assertNotEqual(self.agent.requests[-1]["params"]["query"], "Cursor")

        self.table["get"] = lambda params: get_result(own("m3"), "full-body")
        code, out = self.invoke_full(["get", "m3"], ctx)
        self.assertEqual(code, 0)
        self.assertEqual(self.parse(out)["text"], "full-body")
        self.assertEqual(self.parse(out)["contentTrust"], "untrusted")

        def batch(params):
            if params["messageID"] == "gone":
                raise AgentError("not_found")
            if params["messageID"] == "foreign":
                return get_result(make_message("foreign", account=ACCOUNT), SENTINEL)
            return get_result(own(params["messageID"]), "ok-body")

        self.table["get"] = batch
        code, out = self.invoke_full(["get-batch", "a", "b"], ctx)
        self.assertEqual(code, 0)
        self.assertEqual([entry["status"] for entry in self.parse(out)["results"]],
                         ["ok", "ok"])
        self.assertEqual(self.methods_seen().count("get"), 3)
        code, out = self.invoke_full(["get-batch", "a", "foreign", "gone"], ctx)
        self.assertEqual(code, 5)
        doc = self.parse(out)
        self.assertEqual([entry["status"] for entry in doc["results"]],
                         ["ok", "error", "not_found"])
        self.assertNotIn("message", doc["results"][1])
        self.assertNotIn(SENTINEL, out.decode("utf-8"))
        self.assertIn(("list_messages", "ok"), self.audit_rows())
        self.assertNotIn("get_verification_code",
                         [row[0] for row in self.audit_rows()])

    def test_full_bounds_rejected_without_socket(self):
        rejected = [
            ["list", "--since-days", "31"], ["list", "--since-days", "0"],
            ["list", "--limit", "21"], ["list", "--limit", "0"],
            ["list", "--offset", "1"], ["list", "--offset=0"],
            ["list", "--account", FULL_ACCOUNT], ["list", "--status", "inbox"],
            ["list", "--lim", "5"], ["list", "--since", "3"],
            ["search"], ["search", "--query", ""], ["search", "--query", "   "],
            ["search", "--query", "a\nb"], ["search", "--query", "a;b"],
            ["search", "--query", "a/b"], ["search", "--query", "a" * 129],
            ["search", "--query", "中" * 100],
            ["search", "--query", "ok", "--since-days", "31"],
            ["search", "--query", "\u202ehidden"],
            ["get-batch"] + ["m%d" % i for i in range(6)], ["get-batch"],
            ["get_verification_code"], ["codes"], ["--account", ACCOUNT, "list"],
            ["--help"], [],
        ]
        for argv in rejected:
            with self.subTest(argv=argv):
                code, out = self.invoke_full(argv)
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])
        for argv in (["full", "list", "--limit", "21"],
                     ["full", "search", "--query", "bad/query"],
                     ["full", "get-batch"] + ["m%d" % i for i in range(6)]):
            result = self.cli(argv)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.table["search"] = lambda params: search_result([])
        code, _ = self.invoke_full(["search", "--query", "a" * 128])
        self.assertEqual(code, 0)
        self.assertEqual(self.agent.requests[-1]["params"]["query"], "a" * 128)
        code, _ = self.invoke_full(["search", "--query", "中" * 85])
        self.assertEqual(code, 0)
        self.assertEqual(len(self.agent.requests[-1]["params"]["query"].encode("utf-8")), 255)

    def test_profile_isolation_and_foreign_account(self):
        code, out = self.invoke_full(["list"], self.ctx)
        self.assertEqual((code, self.parse(out)), (2, USAGE_DOC))
        code, out = self.invoke(["accounts"], self.full_ctx())
        self.assertEqual((code, self.parse(out)), (2, USAGE_DOC))
        self.assertEqual(self.agent.requests, [])

        billing = {"account": ACCOUNT, "senders": [ALLOWED]}
        home, listener = self.make_home("iso", billing, agent=True)
        self.write_profile_config(home, "oneshot-full.json", {"account": FULL_ACCOUNT})

        def search(params):
            return search_result([make_message(
                "m", OTHER, account=params["account"])])

        def get(params):
            if params["account"] == FULL_ACCOUNT:
                return get_result(make_message(
                    params["messageID"], OTHER, account=FULL_ACCOUNT), "full-body")
            return get_result(make_message(params["messageID"], OTHER), SENTINEL)

        self.table["search"] = search
        self.table["get"] = get
        code, out, doc = self.invoke_main(["search"], home)
        self.assertEqual(code, 0)
        self.assertEqual(doc["filteredOut"], 1)
        self.assertEqual(doc["items"], [])
        self.assertNotIn(OTHER, out.decode("utf-8"))
        self.assertEqual(listener.requests[-1]["params"]["account"], ACCOUNT)
        self.assertEqual(listener.requests[-1]["params"]["query"], "Cursor")
        code, out, doc = self.invoke_main(["billing", "get", "m1"], home)
        self.assertEqual(code, 3)
        self.assertFalse(doc["allowed"])
        self.assertNotIn(SENTINEL, out.decode("utf-8"))
        before = len(listener.requests)
        code, _, doc = self.invoke_main(
            ["full", "--account", ACCOUNT, "get", "m1"], home)
        self.assertEqual((code, doc), (2, USAGE_DOC))
        self.assertEqual(len(listener.requests), before)
        code, out, doc = self.invoke_main(
            ["full", "search", "--query", "synthetic"], home)
        self.assertEqual(code, 0)
        self.assertEqual(doc["items"][0]["fromEmail"], OTHER)
        self.assertNotIn("filteredOut", doc)
        self.assertEqual(listener.requests[-1]["params"]["account"], FULL_ACCOUNT)
        self.assertEqual(listener.requests[-1]["params"]["query"], "synthetic")
        code, out, doc = self.invoke_main(["full", "get", "m9"], home)
        self.assertEqual(code, 0)
        self.assertEqual(doc["text"], "full-body")
        self.assertEqual(listener.requests[-1]["params"]["account"], FULL_ACCOUNT)

        self.table["get"] = lambda params: get_result(
            make_message("m1", OTHER, subject="SUBJ_SENTINEL"), SENTINEL)
        code, out = self.invoke_full(["get", "m1"])
        self.assertEqual(code, 5)
        self.assertEqual(self.parse(out)["error"], "invalid_response")
        for leak in (SENTINEL, "SUBJ_SENTINEL", ACCOUNT):
            self.assertNotIn(leak, out.decode("utf-8"))
        self.table["list"] = lambda params: search_result([
            make_message("foreign", account=ACCOUNT),
            make_message("own", account=FULL_ACCOUNT)])
        code, out = self.invoke_full(["list"])
        self.assertEqual(code, 5)
        self.assertNotIn("foreign", out.decode("utf-8"))
        with patch.object(pigi_oneshot, "single_call", return_value=(
                "ok", {"accounts": [{"account": ACCOUNT, "kind": "imap"},
                                    {"account": FULL_ACCOUNT, "kind": "imap"}],
                       "contentTrust": "untrusted"})):
            code, out = pigi_oneshot_full.execute(["accounts"], self.full_ctx())
        self.assertEqual(code, 5)
        self.assertNotIn(ACCOUNT, out.decode("utf-8"))

    def test_full_config_fails_closed(self):
        home = self.root / "fullcfg"
        config_dir = home / "Library" / "Application Support" / "pigi"
        with self.assertRaises(pigi_oneshot.ConfigError):
            pigi_oneshot_full.load_config(str(home))
        config_dir.mkdir(parents=True, mode=0o700)
        billing = config_dir / "oneshot.json"
        billing.write_text(json.dumps({"account": ACCOUNT, "senders": [ALLOWED]}))
        os.chmod(billing, 0o600)
        path = config_dir / "oneshot-full.json"
        path.write_text(json.dumps({"account": FULL_ACCOUNT}))
        os.chmod(path, 0o644)
        with self.assertRaises(pigi_oneshot.ConfigError):
            pigi_oneshot_full.load_config(str(home))
        self.assertEqual(pigi_oneshot.load_config(str(home))["account"], ACCOUNT)
        os.chmod(path, 0o600)
        link = config_dir / "extra.json"
        os.link(path, link)
        with self.assertRaises(pigi_oneshot.ConfigError):
            pigi_oneshot_full.load_config(str(home))
        link.unlink()
        path.unlink()
        path.symlink_to(billing)
        with self.assertRaises(pigi_oneshot.ConfigError):
            pigi_oneshot_full.load_config(str(home))
        path.unlink()
        for doc in ({}, {"senders": [ALLOWED]},
                    {"account": FULL_ACCOUNT, "senders": [ALLOWED]},
                    {"account": FULL_ACCOUNT, "extra": 1},
                    {"account": "  "}, {"account": 5},
                    {"account": "x" * 1025}):
            path.write_text(json.dumps(doc))
            os.chmod(path, 0o600)
            with self.assertRaises(pigi_oneshot.ConfigError):
                pigi_oneshot_full.load_config(str(home))
        path.write_text("not json")
        os.chmod(path, 0o600)
        with self.assertRaises(pigi_oneshot.ConfigError):
            pigi_oneshot_full.load_config(str(home))
        os.chmod(config_dir, 0o777)
        path.write_text(json.dumps({"account": FULL_ACCOUNT}))
        os.chmod(path, 0o600)
        with self.assertRaises(pigi_oneshot.ConfigError):
            pigi_oneshot_full.load_config(str(home))
        os.chmod(config_dir, 0o700)
        loaded = pigi_oneshot_full.load_config(str(home))
        self.assertEqual(loaded, {"account": FULL_ACCOUNT})
        self.assertEqual(pigi_oneshot.load_config(str(home))["senders"],
                         frozenset({ALLOWED}))

    def test_missing_full_config_does_not_affect_billing(self):
        home, listener = self.make_home(
            "miss", {"account": ACCOUNT, "senders": [ALLOWED]}, agent=True)
        code, _, doc = self.invoke_main(["full", "accounts"], home)
        self.assertEqual((code, doc), (6, CONFIG_DOC))
        self.assertEqual(listener.requests, [])

        def accounts(params):
            return {"accounts": [{"account": params["account"], "kind": "imap"}],
                    "contentTrust": "untrusted", "capabilities": CAPS}

        self.table["accounts"] = accounts
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual(code, 0)
        self.assertEqual(doc["accounts"][0]["account"], ACCOUNT)
        self.write_profile_config(home, "oneshot-full.json",
                                  {"account": FULL_ACCOUNT}, mode=0o644)
        code, _, doc = self.invoke_main(["full", "list"], home)
        self.assertEqual((code, doc), (6, CONFIG_DOC))
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual(code, 0)
        called = []

        def explode(home_arg):
            called.append(home_arg)
            raise AssertionError("config was read")

        with patch.object(pigi_oneshot, "load_config", explode), \
                patch.object(pigi_oneshot_full, "load_config", explode):
            for argv in (["other", "list"], ["full", "list", "--limit", "21"],
                         ["full", "search", "--query", "a/b"]):
                code, _, doc = self.invoke_main(argv, home)
                self.assertEqual((code, doc), (2, USAGE_DOC))
        self.assertEqual(called, [])

    def test_full_truncation_stays_valid_json(self):
        big = [make_message("m%d" % i, OTHER, account=FULL_ACCOUNT, snippet="A" * 30_000)
               for i in range(3)]
        self.table["list"] = lambda params: search_result(big)
        code, out = self.invoke_full(["list", "--limit", "20"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertEqual(doc["command"], "list")
        self.assertEqual(doc["contentTrust"], "untrusted")
        self.assertNotIn("filteredOut", doc)
        self.assertEqual(len(doc["items"]) + doc["omittedItems"], 3)
        message = make_message("m1", account=FULL_ACCOUNT)
        self.table["get"] = lambda params: get_result(message, "y" * 100_000)
        code, out = self.invoke_full(["get", "m1"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        self.assertTrue(self.parse(out)["textTruncated"])

    def paged_server(self, rows):
        """Swift-like list/search: account+since filter, (date DESC, id ASC)
        order, offset/limit window, nextOffset iff more rows exist."""
        def respond(params):
            matched = [row for row in rows
                       if row["account"] == params["account"]
                       and row["date"] >= params["since"]]
            query = params.get("query")
            if query is not None:
                matched = [row for row in matched if query in row["subject"]]
            matched.sort(key=lambda row: (-row["date"], row["messageID"]))
            offset, limit = params.get("offset", 0), params.get("limit", 50)
            result = {"items": matched[offset:offset + limit],
                      "contentTrust": "untrusted", "capabilities": CAPS}
            if offset + limit < len(matched):
                result["nextOffset"] = offset + limit
            return result
        return respond

    def page_cursor_doc(self, **fields):
        doc = {"v": 1, "c": "list", "q": "", "s": NOW - 365 * 86_400_000,
               "o": 10, "d": NOW - 86_400_000, "i": "m09"}
        doc.update(fields)
        return doc

    def page_cursor(self, doc):
        raw = json.dumps(doc, separators=(",", ":")).encode("utf-8")
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    def page_walk(self, argv, limit):
        """--history then follow nextCursor to end:true; (codes, docs, outs)."""
        codes, docs, outs, tail = [], [], [], ["--history"]
        for _ in range(500):
            code, out = self.invoke_full(argv + tail + ["--limit", str(limit)])
            doc = self.parse(out)
            codes.append(code)
            docs.append(doc)
            outs.append(out)
            if doc["page"]["end"]:
                return codes, docs, outs
            if not isinstance(doc["page"]["nextCursor"], str):
                return codes, docs, outs
            tail = ["--cursor", doc["page"]["nextCursor"]]
        self.fail("history walk did not terminate")

    def test_full_history_walks_all_pages_no_gaps(self):
        day = 86_400_000
        rows = [make_message("a%02d" % i, OTHER, account=FULL_ACCOUNT,
                             date=NOW - 10 * day) for i in range(7)]
        rows += [make_message("b%02d" % i, OTHER, account=FULL_ACCOUNT,
                              date=NOW - 20 * day) for i in range(5)]
        rows += [make_message("c%02d" % i, OTHER, account=FULL_ACCOUNT,
                              date=NOW - (30 + i) * day) for i in range(8)]
        rows += [make_message("old%d" % i, OTHER, account=FULL_ACCOUNT,
                              date=NOW - (400 + i) * day) for i in range(3)]
        rows += [make_message("foreign0", OTHER, account=ACCOUNT, date=NOW)]
        self.table["list"] = self.paged_server(rows)
        expected = [row["messageID"] for row in sorted(
            (row for row in rows
             if row["account"] == FULL_ACCOUNT
             and row["date"] >= NOW - 365 * day),
            key=lambda row: (-row["date"], row["messageID"]))]
        self.assertEqual(len(expected), 20)
        for limit in (1, 5, 20):
            with self.subTest(limit=limit):
                codes, docs, outs = self.page_walk(["list"], limit)
                self.assertEqual(codes, [0] * len(codes))
                self.assertEqual(len(docs), -(-20 // limit))
                got = [item["messageID"] for doc in docs
                       for item in doc["items"]]
                self.assertEqual(got, expected)
                for out in outs:
                    self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
                for doc in docs[:-1]:
                    self.assertFalse(doc["page"]["end"])
                    self.assertIsInstance(doc["page"]["nextCursor"], str)
                self.assertEqual(docs[-1]["page"],
                                 {"end": True, "nextCursor": None})
                if limit == 5:
                    # 7 same-date messages straddle two pages; page 1 is a
                    # whole page at a single timestamp.
                    self.assertEqual(len(docs[0]["items"]), 5)
                    self.assertEqual(
                        {item["date"] for item in docs[0]["items"]},
                        {NOW - 10 * day})
                    self.assertEqual([item["messageID"]
                                      for item in docs[1]["items"]][:2],
                                     ["a05", "a06"])
        code, out = self.invoke_full(["list"])
        self.assertEqual(code, 0)
        self.assertNotIn("page", self.parse(out))

    def test_full_history_upstream_params(self):
        day = 86_400_000
        rows = [make_message("m%03d" % i, OTHER, account=FULL_ACCOUNT,
                             date=NOW - i * day) for i in range(70)]
        self.table["list"] = self.paged_server(rows)
        codes, docs, _ = self.page_walk(["list"], 5)
        self.assertEqual(codes, [0] * 14)
        for request in self.agent.requests:
            self.assertEqual(request["method"], "list")
            self.assertEqual(request["params"]["account"], FULL_ACCOUNT)
            self.assertEqual(request["params"]["since"], NOW - 365 * day)
            self.assertEqual(request["params"]["limit"], 100)
        offsets = [request["params"]["offset"]
                   for request in self.agent.requests]
        self.assertEqual(offsets, [0] * 9 + [5, 10, 15, 20, 25])

    def test_full_search_history_and_cursor_binding(self):
        day = 86_400_000
        rows = [make_message("s%02d" % i, OTHER, account=FULL_ACCOUNT,
                             date=NOW - i * day, subject="Report %02d" % i)
                for i in range(12)]
        rows += [make_message("u%02d" % i, OTHER, account=FULL_ACCOUNT,
                              date=NOW - i * day, subject="Other mail")
                 for i in range(5)]
        self.table["search"] = self.paged_server(rows)
        expected = ["s%02d" % i for i in range(12)]
        codes, docs, _ = self.page_walk(["search", "--query", "Report"], 5)
        self.assertEqual(codes, [0] * len(codes))
        self.assertEqual(len(docs), 3)
        self.assertEqual([item["messageID"] for doc in docs
                          for item in doc["items"]], expected)
        search_token = docs[0]["page"]["nextCursor"]
        self.table["list"] = self.paged_server(rows)
        code, out = self.invoke_full(["list", "--history", "--limit", "2"])
        self.assertEqual(code, 0)
        list_token = self.parse(out)["page"]["nextCursor"]
        for argv in (["search", "--query", "Report", "--cursor", list_token],
                     ["list", "--cursor", search_token],
                     ["search", "--query", "Other", "--cursor", search_token]):
            with self.subTest(argv=argv):
                code, out = self.invoke_full(argv)
                self.assertEqual((code, self.parse(out)), (2, USAGE_DOC))
        self.assertEqual(len(self.agent.requests), 4)

    def test_full_history_mutations_between_pages(self):
        day = 86_400_000

        def fresh(count=12):
            return [make_message("m%02d" % i, OTHER, account=FULL_ACCOUNT,
                                 date=NOW - i * day) for i in range(count)]

        def start(rows, limit=5):
            self.table["list"] = self.paged_server(rows)
            code, out = self.invoke_full(
                ["list", "--history", "--limit", str(limit)])
            self.assertEqual(code, 0)
            return self.parse(out)

        def finish(rows, doc, limit=5):
            ids = []
            while True:
                code, out = self.invoke_full(
                    ["list", "--cursor", doc["page"]["nextCursor"],
                     "--limit", str(limit)])
                self.assertEqual(code, 0)
                doc = self.parse(out)
                ids += [item["messageID"] for item in doc["items"]]
                if doc["page"]["end"]:
                    self.assertIsNone(doc["page"]["nextCursor"])
                    return ids

        # (a) new mail at the top: no dup, no gap in older items.
        rows = fresh()
        expected = [row["messageID"] for row in rows]
        doc = start(rows)
        ids = [item["messageID"] for item in doc["items"]]
        rows.append(make_message("new0", OTHER, account=FULL_ACCOUNT,
                                 date=NOW + day))
        self.assertEqual(ids + finish(rows, doc), expected)

        # (b) a message older than the anchor deleted between pages.
        rows = fresh()
        doc = start(rows)
        ids = [item["messageID"] for item in doc["items"]]
        del rows[7]
        self.assertEqual(ids + finish(rows, doc),
                         [row["messageID"] for row in rows])

        # (c) the anchor message itself deleted between pages; it was already
        # emitted on the first page, so the walk still covers every id once.
        rows = fresh()
        expected = [row["messageID"] for row in rows]
        doc = start(rows)
        ids = [item["messageID"] for item in doc["items"]]
        self.assertEqual(ids[-1], "m04")
        del rows[4]
        self.assertEqual(ids + finish(rows, doc), expected)

        # (d) more than BACK deletions before the anchor fail closed.
        rows = fresh(70)
        doc = start(rows, 20)
        for _ in range(2):
            code, out = self.invoke_full(
                ["list", "--cursor", doc["page"]["nextCursor"], "--limit", "20"])
            self.assertEqual(code, 0)
            doc = self.parse(out)
        token = doc["page"]["nextCursor"]
        del rows[:41]
        code, out = self.invoke_full(
            ["list", "--cursor", token, "--limit", "20"])
        self.assertEqual(code, 5)
        self.assertEqual(self.parse(out),
                         {"contentTrust": "untrusted", "error": "cursor_stale"})
        self.assertNotIn("items", self.parse(out))

    def test_full_history_rejects_bad_rows(self):
        day = 86_400_000
        good = [make_message("m%02d" % i, OTHER, account=FULL_ACCOUNT,
                             date=NOW - i * day) for i in range(6)]

        def raw(items):
            return lambda params: {"items": items, "contentTrust": "untrusted",
                                   "capabilities": CAPS}

        cases = {
            "foreign": raw([make_message("x", OTHER, account=ACCOUNT,
                                         date=NOW)]),
            "ascending": raw(list(reversed(good))),
            "duplicate": raw([good[0], good[0]]),
            "str_date": raw([dict(good[0], date="yesterday")]),
            "non_str_id": raw([dict(good[0], messageID=7)]),
            "not_a_list": raw({}),
        }
        for label, responder in cases.items():
            with self.subTest(label=label):
                self.table["list"] = responder
                code, out = self.invoke_full(["list", "--history"])
                self.assertEqual(code, 5)
                self.assertEqual(self.parse(out)["error"], "invalid_response")

    def test_full_history_oversize_pages_keep_every_item(self):
        day = 86_400_000
        rows = [make_message("big%02d" % i, OTHER, account=FULL_ACCOUNT,
                             date=NOW - i * day,
                             snippet="B" * 30_000 + str(i))
                for i in range(9)]
        self.table["list"] = self.paged_server(rows)
        codes, docs, outs = self.page_walk(["list"], 5)
        self.assertEqual(codes, [0] * len(codes))
        self.assertEqual([item["messageID"] for doc in docs
                          for item in doc["items"]],
                         ["big%02d" % i for i in range(9)])
        self.assertTrue(all(len(out) <= pigi_oneshot.MAX_STDOUT
                            for out in outs))
        self.assertTrue(any(len(doc["items"]) < 5 for doc in docs))
        self.assertEqual(docs[-1]["page"], {"end": True, "nextCursor": None})

    def test_full_history_single_oversize_item_exit_eight(self):
        """Review reproduction: an oversized message is delivered with its
        text fields cut — identity delivered, nothing skipped — exit 8."""
        day = 86_400_000
        rows = [make_message("huge", OTHER, account=FULL_ACCOUNT, date=NOW,
                             snippet="H" * 100_000),
                make_message("tail", OTHER, account=FULL_ACCOUNT,
                             date=NOW - day)]
        self.table["list"] = self.paged_server(rows)
        code, out = self.invoke_full(["list", "--history", "--limit", "5"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertEqual(doc["truncationNotice"],
                         pigi_oneshot.TRUNCATION_NOTICE)
        self.assertIsInstance(doc["originalBytes"], int)
        self.assertGreater(doc["originalBytes"], pigi_oneshot.MAX_STDOUT)
        self.assertEqual(doc["command"], "list")
        self.assertEqual(len(doc["items"]), 1)
        item = doc["items"][0]
        self.assertEqual(item["messageID"], "huge")
        self.assertEqual(item["account"], FULL_ACCOUNT)
        self.assertEqual(item["date"], NOW)
        self.assertEqual(item["truncatedFields"], ["snippet"])
        self.assertNotIn("omittedItems", doc)
        self.assertFalse(doc["page"]["end"])
        token = doc["page"]["nextCursor"]
        self.assertIsInstance(token, str)
        code, out = self.invoke_full(
            ["list", "--cursor", token, "--limit", "5"])
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual([item["messageID"] for item in doc["items"]], ["tail"])
        self.assertEqual(doc["page"], {"end": True, "nextCursor": None})

    def test_full_history_oversize_item_walk_loses_nothing(self):
        """Every page fits, the union of messageIDs is complete and ordered,
        and exit 8 appears on exactly the pages carrying a cut item."""
        day = 86_400_000
        rows = [make_message("m1", OTHER, account=FULL_ACCOUNT, date=NOW),
                make_message("big", OTHER, account=FULL_ACCOUNT,
                             date=NOW - day, subject="S" * 40_000,
                             snippet="B" * 100_000),
                make_message("m3", OTHER, account=FULL_ACCOUNT,
                             date=NOW - 2 * day)]
        for limit in (1, 20):
            with self.subTest(limit=limit):
                self.table["list"] = self.paged_server(rows)
                codes, docs, outs = self.page_walk(["list"], limit)
                self.assertTrue(all(
                    len(out) <= pigi_oneshot.MAX_STDOUT for out in outs))
                got = [item["messageID"] for doc in docs
                       for item in doc["items"]]
                self.assertEqual(got, ["m1", "big", "m3"])
                cut_pages = [index for index, doc in enumerate(docs)
                             if doc.get("truncated")]
                self.assertEqual(len(cut_pages), 1)
                index = cut_pages[0]
                self.assertEqual(codes[index], 8)
                self.assertEqual([code for code in codes if code != 8],
                                 [0] * (len(codes) - 1))
                item = docs[index]["items"][0]
                self.assertEqual(item["messageID"], "big")
                self.assertEqual(item["account"], FULL_ACCOUNT)
                self.assertEqual(item["date"], NOW - day)
                self.assertEqual(item["truncatedFields"],
                                 ["snippet", "subject"])
                self.assertEqual(docs[-1]["page"],
                                 {"end": True, "nextCursor": None})
        # Same guarantee with the oversized item first and last in the walk.
        rows = [make_message("first", OTHER, account=FULL_ACCOUNT, date=NOW,
                             snippet="F" * 100_000)]
        rows += [make_message("m%02d" % i, OTHER, account=FULL_ACCOUNT,
                              date=NOW - i * day) for i in range(1, 4)]
        rows += [make_message("last", OTHER, account=FULL_ACCOUNT,
                              date=NOW - 4 * day, snippet="L" * 100_000)]
        self.table["list"] = self.paged_server(rows)
        codes, docs, outs = self.page_walk(["list"], 10)
        self.assertTrue(all(len(out) <= pigi_oneshot.MAX_STDOUT
                            for out in outs))
        got = [item["messageID"] for doc in docs for item in doc["items"]]
        self.assertEqual(got, ["first", "m01", "m02", "m03", "last"])
        self.assertEqual(codes.count(8), 2)
        self.assertEqual(len([doc for doc in docs if doc.get("truncated")]),
                         2)
        self.assertEqual(docs[-1]["page"], {"end": True, "nextCursor": None})

    def test_full_history_page_item_too_large_fails_closed(self):
        """An item that cannot fit even with every cuttable field cut to 0
        fails closed: exit 5 page_item_too_large, nothing delivered."""
        day = 86_400_000
        rows = [make_message("m0", OTHER, account=FULL_ACCOUNT, date=NOW),
                make_message("blob", OTHER, account=FULL_ACCOUNT,
                             date=NOW - day,
                             extra={"blob": list(range(40_000))}),
                make_message("m2", OTHER, account=FULL_ACCOUNT,
                             date=NOW - 2 * day)]
        self.table["list"] = self.paged_server(rows)
        code, out = self.invoke_full(["list", "--history", "--limit", "1"])
        self.assertEqual(code, 0)
        token = self.parse(out)["page"]["nextCursor"]
        code, out = self.invoke_full(
            ["list", "--cursor", token, "--limit", "1"])
        self.assertEqual(code, 5)
        self.assertEqual(self.parse(out),
                         {"contentTrust": "untrusted",
                          "error": "page_item_too_large"})
        self.assertNotIn("items", self.parse(out))
        self.assertNotIn("page", self.parse(out))
        # A messageID too big to ever fit is also undeliverable: identity
        # fields are never cut.
        rows = [make_message("X" * 70_000, OTHER, account=FULL_ACCOUNT,
                             date=NOW)]
        self.table["list"] = self.paged_server(rows)
        code, out = self.invoke_full(["list", "--history", "--limit", "5"])
        self.assertEqual(code, 5)
        self.assertEqual(self.parse(out)["error"], "page_item_too_large")

    def test_full_history_unanchorable_id_fails_closed(self):
        """A row whose messageID cannot be embedded in a cursor this tool
        accepts must not emit a nextCursor the parser would reject."""
        day = 86_400_000
        for bad_id in ("X" * 300, "bad\nid", "X" * 70_000):
            with self.subTest(bad_id=bad_id[:10]):
                rows = [make_message("m0", OTHER, account=FULL_ACCOUNT,
                                     date=NOW),
                        make_message(bad_id, OTHER, account=FULL_ACCOUNT,
                                     date=NOW - day),
                        make_message("m2", OTHER, account=FULL_ACCOUNT,
                                     date=NOW - 2 * day)]
                self.table["list"] = self.paged_server(rows)
                code, out = self.invoke_full(
                    ["list", "--history", "--limit", "2"])
                self.assertEqual(code, 5)
                self.assertEqual(
                    self.parse(out),
                    {"contentTrust": "untrusted",
                     "error": "invalid_response"})
                self.assertNotIn("items", self.parse(out))

    def test_full_history_emitted_cursors_round_trip(self):
        """Every nextCursor emitted is accepted by this tool's own parser
        and passes the horizon check run_command applies."""
        day = 86_400_000
        rows = [make_message("m%02d" % i, OTHER, account=FULL_ACCOUNT,
                             date=NOW - i * day) for i in range(12)]
        self.table["list"] = self.paged_server(rows)
        codes, docs, _ = self.page_walk(["list"], 5)
        self.assertEqual(codes, [0] * len(codes))
        horizon = NOW - 365 * day
        for doc in docs[:-1]:
            token = doc["page"]["nextCursor"]
            args = pigi_oneshot_full.parse_args(["list", "--cursor", token])
            self.assertTrue(
                horizon - pigi_oneshot_full.CURSOR_TTL_MS
                <= args.cursor["s"]
                <= horizon + pigi_oneshot_full.CLOCK_SKEW_MS)

    def test_full_paging_arguments_rejected_without_socket(self):
        day = 86_400_000
        good = self.page_cursor_doc()
        token = self.page_cursor(good)
        docs = [
            self.page_cursor_doc(x=1),                          # extra key
            {key: value for key, value in good.items() if key != "i"},
            self.page_cursor_doc(v=True),                       # bool for int
            self.page_cursor_doc(v=2),
            self.page_cursor_doc(s="123"),                      # str for int
            self.page_cursor_doc(o=1.5),                        # float for int
            self.page_cursor_doc(o=-1),
            self.page_cursor_doc(o=1_000_001),
            self.page_cursor_doc(d=False),                      # bool date
            self.page_cursor_doc(i=5),                          # non-str id
            self.page_cursor_doc(i=""),
            self.page_cursor_doc(i="x" * 257),
            self.page_cursor_doc(i="has\nnewline"),
            self.page_cursor_doc(i="中"),                       # non-ASCII id
            self.page_cursor_doc(c="bogus"),
            self.page_cursor_doc(c="search"),                   # wrong subcommand
            self.page_cursor_doc(q=7),
            self.page_cursor_doc(o=0),                        # offsets start at 1
            self.page_cursor_doc(o=0, d=10**40),
            self.page_cursor_doc(d=10**40),                   # above MAX_SAFE_MS
            self.page_cursor_doc(d=pigi_oneshot_full.MAX_SAFE_MS + 1),
            self.page_cursor_doc(s=pigi_oneshot_full.MAX_SAFE_MS + 1),
            self.page_cursor_doc(d=NOW - 366 * day),          # d < s
        ]
        rejected = [
            ["list", "--history", "--cursor", token],
            ["list", "--history", "--cursor=" + token],
            ["list", "--history", "--since-days", "3"],
            ["list", "--cursor", token, "--since-days", "3"],
            ["search", "--query", "ok", "--history", "--cursor", token],
            ["search", "--query", "ok", "--cursor", token,
             "--since-days", "3"],
            ["list", "--cursor"],
            ["list", "--cursor", ""],
            ["list", "--cursor", "%%%"],
            ["list", "--cursor", "aGVsbG8"],                    # base64, not JSON
            ["list", "--cursor", "e30"],                        # {} missing keys
            ["list", "--history", "--history"],
            ["list", "--history=1"],
            ["list", "--cursor", token, "--cursor", token],
            ["list", "--cursor", token, "--limit", "21"],
            ["list", "--history", "--limit", "0"],
            ["list", "--offset", "5"],
            ["get", "m1", "--cursor", token],
            ["get", "m1", "--history"],
            ["get-batch", "m1", "--history"],
            ["get-batch", "m1", "--cursor", token],
            ["accounts", "--history"],
            ["accounts", "--cursor", token],
        ]
        rejected += [["list", "--cursor", self.page_cursor(doc)]
                     for doc in docs]
        rejected.append(["list", "--cursor", self.page_cursor(
            self.page_cursor_doc(i="x" * 900))])                # token > 1024
        for argv in rejected:
            with self.subTest(argv=argv[:3]):
                code, out = self.invoke_full(argv)
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])

        # Structurally valid cursors whose s is off the --history horizon are
        # rejected in run_command before any upstream call: a token is only
        # usable for CURSOR_TTL_MS (+CLOCK_SKEW_MS drift) after its mint.
        ttl = pigi_oneshot_full.CURSOR_TTL_MS
        skew = pigi_oneshot_full.CLOCK_SKEW_MS
        horizon = NOW - 365 * day
        for fields in ({"s": NOW - 366 * day},
                       {"s": horizon - ttl - 1},
                       {"s": NOW - 364 * day},
                       {"s": horizon + skew + 1},
                       {"s": NOW, "d": NOW}):
            stale = self.page_cursor(self.page_cursor_doc(**fields))
            code, out = self.invoke_full(["list", "--cursor", stale])
            self.assertEqual((code, self.parse(out)), (2, USAGE_DOC))
        self.assertEqual(self.agent.requests, [])
        # Positive boundaries: a fresh mint, one second before expiry, and a
        # far-future anchor all reach the socket.
        self.table["list"] = self.paged_server([])
        for fields in ({"s": horizon},
                       {"s": horizon - ttl + 1000},
                       {"o": 1, "d": pigi_oneshot_full.MAX_SAFE_MS}):
            edge = self.page_cursor(self.page_cursor_doc(**fields))
            code, out = self.invoke_full(["list", "--cursor", edge])
            self.assertEqual((code, self.parse(out)["page"]),
                             (0, {"end": True, "nextCursor": None}))
        self.assertEqual(len(self.agent.requests), 3)

        # The real-clock invoke_main/run_main path rejects the same bounds.
        home, listener = self.make_home(
            "pgt", {"account": ACCOUNT, "senders": [ALLOWED]}, agent=True)
        self.write_profile_config(home, "oneshot-full.json",
                                  {"account": FULL_ACCOUNT})
        real_now = int(time.time() * 1000)
        structural = [
            {"o": 0},
            {"o": 0, "d": 10**40},
            {"o": 1, "d": 10**40},
            {"d": pigi_oneshot_full.MAX_SAFE_MS + 1},
            {"s": pigi_oneshot_full.MAX_SAFE_MS + 1},
            {"s": real_now - 365 * day, "d": real_now - 366 * day},
        ]
        horizon_cases = [
            {"s": 1},
            {"s": real_now - 366 * day},
            {"s": real_now - 365 * day - ttl - 1},
            {"s": real_now - 364 * day},
            {"s": real_now},
        ]
        # Structural rejects exit at parse, before the config file is read;
        # horizon rejects run in run_command after config, before the socket.
        def explode(home_arg):
            raise AssertionError("config was read")

        with patch.object(pigi_oneshot, "load_config", explode), \
                patch.object(pigi_oneshot_full, "load_config", explode):
            bad = [["full", "list", "--history", "--cursor", token],
                   ["full", "list", "--cursor", "not-a-token"],
                   ["full", "get", "m1", "--cursor", token],
                   ["full", "accounts", "--history"]]
            bad += [["full", "list", "--cursor",
                     self.page_cursor(self.page_cursor_doc(**fields))]
                    for fields in structural]
            for argv in bad:
                code, _, doc = self.invoke_main(argv, home)
                self.assertEqual((code, doc), (2, USAGE_DOC))
        for fields in horizon_cases:
            stale = self.page_cursor(self.page_cursor_doc(**fields))
            code, _, doc = self.invoke_main(
                ["full", "list", "--cursor", stale], home)
            self.assertEqual((code, doc), (2, USAGE_DOC))
        self.assertEqual(listener.requests, [])

    def test_billing_profile_rejects_paging_options(self):
        token = self.page_cursor(self.page_cursor_doc())
        for argv in (["search", "--history"], ["search", "--cursor", token],
                     ["billing", "search", "--history"],
                     ["billing", "search", "--cursor", token],
                     ["billing", "list", "--history"], ["list", "--history"],
                     ["billing", "get", "m1", "--history"],
                     ["billing", "accounts", "--cursor", token]):
            with self.subTest(argv=argv):
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])

    def test_launcher_forwards_history_args(self):
        home, listener = self.make_home(
            "lh", {"account": ACCOUNT, "senders": [ALLOWED]}, agent=True)
        self.write_profile_config(home, "oneshot-full.json",
                                  {"account": FULL_ACCOUNT})
        env, canaries = self.make_hooks()
        launch_dir = self.root / "lh-sh"
        launch_dir.mkdir()
        launcher = self.render_launcher(launch_dir, synthetic_python(),
                                      SCRIPT, home)
        # Argument rejection exits 2 before the pinned home is touched.
        result = subprocess.run(
            [str(launcher), "full", "list", "--history", "--cursor", "x"],
            capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertFalse(canaries["bash_env"].exists())
        # A real paged run: script copy with PINNED_HOME pointed at the fake.
        runtime = self.root / "lh-runtime"
        runtime.mkdir()
        for name in ("pigi_oneshot.py", "pigi_oneshot_full.py", "pigi_mcp.py",
                     "transport.py", "audit.py"):
            shutil.copyfile(SCRIPT.parent / name, runtime / name)
        script = runtime / "pigi_oneshot.py"
        pinned = 'PINNED_HOME = "/Users/tr"'
        text = script.read_text()
        self.assertEqual(text.count(pinned), 1)
        script.write_text(text.replace(
            pinned, "PINNED_HOME = " + repr(str(home)), 1))
        launcher = self.render_launcher(launch_dir, synthetic_python(),
                                      script, home)
        item = make_message("m1", OTHER, account=FULL_ACCOUNT)
        self.table["list"] = lambda params: {
            "items": [item], "contentTrust": "untrusted", "capabilities": CAPS}
        result = subprocess.run([str(launcher), "full", "list", "--history"],
                                capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        doc = json.loads(result.stdout)
        self.assertEqual(doc["page"], {"end": True, "nextCursor": None})
        params = listener.requests[-1]["params"]
        self.assertEqual(params["offset"], 0)
        self.assertEqual(params["limit"], 100)
        self.assertEqual(params["account"], FULL_ACCOUNT)

    def test_launcher_rejects_out_of_bounds_cursor(self):
        """Real .sh entry: out-of-bounds cursors exit 2 before the socket
        while parse-clean args reach the config check (exit 6)."""
        home, listener = self.make_home(
            "lb", {"account": ACCOUNT, "senders": [ALLOWED]}, agent=True)
        self.write_profile_config(home, "oneshot-full.json",
                                  {"account": FULL_ACCOUNT})
        env, canaries = self.make_hooks()
        launch_dir = self.root / "lb-sh"
        launch_dir.mkdir()
        runtime = self.root / "lb-runtime"
        runtime.mkdir()
        for name in ("pigi_oneshot.py", "pigi_oneshot_full.py", "pigi_mcp.py",
                     "transport.py", "audit.py"):
            shutil.copyfile(SCRIPT.parent / name, runtime / name)
        script = runtime / "pigi_oneshot.py"
        pinned = 'PINNED_HOME = "/Users/tr"'
        text = script.read_text()
        self.assertEqual(text.count(pinned), 1)
        script.write_text(text.replace(
            pinned, "PINNED_HOME = " + repr(str(home)), 1))
        launcher = self.render_launcher(launch_dir, synthetic_python(),
                                      script, home)
        real_now = int(time.time() * 1000)
        cases = [
            ("structural", {"o": 0, "d": 10**40}),
            ("horizon", {"s": real_now - 366 * 86_400_000}),
        ]
        for label, fields in cases:
            for argv in (["full", "list"],
                         ["full", "search", "--query", "ok"]):
                with self.subTest(case=label, argv=argv[1]):
                    doc_fields = dict(fields)
                    if argv[1] == "search":
                        doc_fields.update(
                            c="search",
                            q=pigi_oneshot_full.query_digest("ok"))
                    token = self.page_cursor(
                        self.page_cursor_doc(**doc_fields))
                    result = subprocess.run(
                        [str(launcher), *argv, "--cursor", token],
                        capture_output=True, timeout=20, env=env)
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(result.stderr, b"")
                    self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(listener.requests, [])
        self.assertFalse(canaries["bash_env"].exists())
        # Contrast: --history parses fine, so a config-less home reaches the
        # config check and exits 6 — rejection above happened earlier.
        home2, _ = self.make_home("lb2")
        script.write_text(text.replace(
            pinned, "PINNED_HOME = " + repr(str(home2)), 1))
        launcher2 = self.render_launcher(launch_dir, synthetic_python(),
                                         script, home2)
        result = subprocess.run([str(launcher2), "full", "list", "--history"],
                                capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 6)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(self.parse(result.stdout), CONFIG_DOC)

    def test_docs_describe_history_paging(self):
        doc = DOCS.read_text()
        for needle in ("--history", "--cursor", "nextCursor",
                       "cursor_stale", "365"):
            self.assertIn(needle, doc)

    def test_full_module_has_no_write_or_code_path(self):
        source = FULL_SCRIPT.read_text()
        for forbidden in ("get_verification_code", '"codes"', "mail.db",
                          "Keychain", "SecItem", "urllib", "webbrowser", "smtplib"):
            self.assertNotIn(forbidden, source)
        self.assertIn("list_messages", source)
        billing = SCRIPT.read_text()
        for forbidden in ('"list"', '"codes"', "get_verification_code", "list_messages"):
            self.assertNotIn(forbidden, billing)

    def test_launcher_forwards_visible_full_token(self):
        home, _ = self.make_home("lfull")
        launch_dir = self.root / "lfull-sh"
        launch_dir.mkdir()
        launcher = self.render_launcher(launch_dir, synthetic_python(), SCRIPT, home)
        env, canaries = self.make_hooks()
        result = subprocess.run(
            [str(launcher), "full", "search", "--since-days", "31"],
            capture_output=True, timeout=20, env=env)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertFalse(canaries["bash_env"].exists())

    def test_launcher_full_config_failures_exit_six(self):
        """Real .sh entry, not an in-process main() call.

        The script runs as __main__. Configuration failures must still be
        exit 6, and must not open the socket.
        """
        home, listener = self.make_home(
            "entry", {"account": ACCOUNT, "senders": [ALLOWED]}, agent=True)
        runtime = self.root / "runtime"
        runtime.mkdir()
        for name in ("pigi_oneshot.py", "pigi_oneshot_full.py", "pigi_mcp.py",
                     "transport.py", "audit.py"):
            shutil.copyfile(SCRIPT.parent / name, runtime / name)
        script = runtime / "pigi_oneshot.py"
        pinned = 'PINNED_HOME = "/Users/tr"'
        text = script.read_text()
        self.assertEqual(text.count(pinned), 1)
        script.write_text(text.replace(pinned, "PINNED_HOME = " + repr(str(home)), 1))
        self.assertEqual(SCRIPT.read_text().count(pinned), 1)
        launcher = self.render_launcher(runtime, synthetic_python(), script, home)
        self.table["accounts"] = lambda params: {
            "accounts": [{"account": params["account"], "kind": "imap"}],
            "contentTrust": "untrusted", "capabilities": CAPS}
        config = home / "Library" / "Application Support" / "pigi" / "oneshot-full.json"

        def launch(argv):
            before = len(listener.requests)
            result = subprocess.run([str(launcher), *argv], capture_output=True,
                                    timeout=20)
            self.assertEqual(result.stderr, b"")
            self.assertLessEqual(len(result.stdout), pigi_oneshot.MAX_STDOUT)
            doc = json.loads(result.stdout)
            self.assertEqual(doc["contentTrust"], "untrusted")
            return result, doc, len(listener.requests) - before

        failures = [
            ("missing", None, None),
            ("malformed", "not json", 0o600),
            ("wrong-shape", "{}", 0o600),
            ("unsafe-mode", json.dumps({"account": FULL_ACCOUNT}), 0o644),
        ]
        for label, value, mode in failures:
            with self.subTest(label=label, profile="full"):
                if value is None:
                    config.unlink(missing_ok=True)
                else:
                    config.write_text(value)
                    os.chmod(config, mode)
                result, doc, delta = launch(["full", "accounts"])
                self.assertEqual(result.returncode, 6)
                self.assertEqual(doc, CONFIG_DOC)
                self.assertEqual(delta, 0)
            with self.subTest(label=label, profile="billing"):
                result, doc, delta = launch(["billing", "accounts"])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(doc["command"], "accounts")
                self.assertEqual(doc["accounts"],
                                 [{"account": ACCOUNT, "kind": "imap"}])
                self.assertEqual(delta, 1)
                self.assertEqual(listener.requests[-1]["params"]["account"], ACCOUNT)
        config.write_text(json.dumps({"account": FULL_ACCOUNT}))
        os.chmod(config, 0o600)
        result, doc, delta = launch(["full", "accounts"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(doc["accounts"], [{"account": FULL_ACCOUNT, "kind": "imap"}])
        self.assertEqual(delta, 1)
        self.assertEqual(listener.requests[-1]["params"]["account"], FULL_ACCOUNT)
        result, doc, delta = launch(["accounts"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(doc["accounts"][0]["account"], ACCOUNT)
        self.assertEqual(listener.requests[-1]["params"]["account"], ACCOUNT)

    def test_docs_describe_both_profiles(self):
        doc = DOCS.read_text()
        self.assertIn("oneshot.json", doc)
        self.assertIn("oneshot-full.json", doc)
        self.assertIn("pigi_oneshot.sh full", doc)
        self.assertIn("pigi_oneshot.sh billing", doc)
        self.assertIn("0600", doc)
        self.assertIn("任何邮件都会进入调用方上下文", doc)
        self.assertIn("contentTrust", doc)
        self.assertIn("256", doc)
        self.assertIn("1–30", doc)
        transition = (REPO_ROOT / "docs" / "billing-ssh-transition.md").read_text()
        self.assertIn("billing profile", transition)
        self.assertIn("oneshot-full.json", transition)


if __name__ == "__main__":
    unittest.main()
