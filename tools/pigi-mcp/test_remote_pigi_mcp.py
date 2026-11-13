"""Synthetic scope and SSH command tests; no real network or mail access."""
import shlex
import sqlite3
import unittest
from unittest.mock import patch

from pigi_mcp import MCPServer
from remote_pigi_mcp import main, ssh_command
import test_pigi_mcp as fixture
from test_pigi_mcp import call, request
from transport import ToolError


class ScopeTests(unittest.TestCase):
    rows = fixture.MCPTests.rows

    def setUp(self):
        fixture.MCPTests.setUp(self)
        self.server = MCPServer(self.client, self.audit, "a@example.invalid")
        self.server.state = "ready"

    # Use only the new scope tests here; unscoped regression tests run separately.
    def test_scope_defaults_and_rejection_are_audited(self):
        self.server.handle(call(2, "list_messages"))
        self.client.call.assert_called_once_with("list", {"account": "a@example.invalid"})
        self.client.reset_mock()
        response = self.server.handle(call(3, "search", {"query": "private", "account": "b@example.invalid"}))
        self.assertIn("permission_denied", str(response))
        self.client.call.assert_not_called()
        self.assertEqual([r[1] for r in self.rows()], ["ok", "permission_denied"])
        self.assertNotIn("private", str(self.rows()))

    def test_scope_discovery_and_mutations_blocked(self):
        tools = self.server.handle(request(2, "tools/list"))["result"]["tools"]
        self.assertEqual({t["name"] for t in tools}, {"list_messages", "search", "get_message"})
        for name in ("list_accounts", "get_verification_code", "send", "draft", "organize"):
            self.assertEqual(self.server.handle(call(3, name))["error"]["code"], -32602)
        self.client.call.assert_not_called()
        self.assertEqual(len(self.rows()), 5)

    def test_scope_revoked_and_audit_failure(self):
        self.client.call.side_effect = ToolError("permission_denied")
        self.assertIn("permission_denied", str(self.server.handle(call(2, "list_messages"))))
        self.assertEqual(self.rows()[0][1], "permission_denied")
        self.client.reset_mock()
        with patch.object(self.audit, "begin", side_effect=sqlite3.OperationalError()):
            self.assertIn("audit_unavailable", str(self.server.handle(call(3, "list_messages"))))
        self.client.call.assert_not_called()



class SSHTests(unittest.TestCase):
    def test_remote_shell_arguments_are_quoted(self):
        script = "/fixture path/$(touch nope);'/pigi_mcp.py"
        account = "a'$(touch nope)@example.invalid"
        command = ssh_command("owner@mini", script, account)
        self.assertEqual(shlex.split(command[-1]), ["python3", "-B", script, "--account", account])
        self.assertEqual(command[-2], "owner@mini")
        for option in ("BatchMode=yes", "StrictHostKeyChecking=yes", "ClearAllForwardings=yes",
                       "ForwardAgent=no", "ForwardX11=no", "PermitLocalCommand=no", "ControlPath=none"):
            self.assertIn(option, command)
        self.assertIn("-T", command)

    def test_invalid_destinations_and_paths(self):
        for host in ("-oProxyCommand=bad", "ssh://mini", "a b", "mini;touch", "user@-mini", ""):
            with self.assertRaises(ValueError):
                ssh_command(host, "/fixture/pigi_mcp.py", "a@example.invalid")
        for script in ("relative/pigi_mcp.py", "/tmp/other.py", "/bad\x00/pigi_mcp.py"):
            with self.assertRaises(ValueError):
                ssh_command("mini", script, "a@example.invalid")
        with self.assertRaises(ValueError):
            ssh_command("mini", "/fixture/pigi_mcp.py", "")
        with self.assertRaises(ValueError):
            ssh_command("mini", "/fixture/pigi_mcp.py", "a@example.invalid", "python3;bad")

    def test_launcher_execs_ssh_with_inherited_stdio(self):
        argv = ["remote_pigi_mcp.py", "--host", "mini", "--remote-script", "/fixture/pigi_mcp.py",
                "--account", "a@example.invalid"]
        with patch("sys.argv", argv), patch("os.execvp", side_effect=OSError()) as execute, patch("sys.stderr") as stderr:
            self.assertEqual(main(), 1)
            execute.assert_called_once_with("ssh", ssh_command("mini", "/fixture/pigi_mcp.py", "a@example.invalid"))
            self.assertTrue(stderr.write.called)
