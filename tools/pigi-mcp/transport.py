"""Bounded protocol-v1 client. Never opens the mail database or Keychain."""
import json
import os
from pathlib import Path
import socket
import stat
import sys
import time
import uuid

DEFAULT_SOCKET = Path.home() / "Library/Application Support/pigi/agent.sock"
MAX_REQUEST = 65_536
MAX_RESPONSE = 2_097_152
ERRORS = {"invalid_request", "unsupported_version", "method_not_found", "not_found",
          "unauthorized", "permission_denied", "audit_unavailable", "too_large", "timeout", "internal_error"}


class ToolError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def decode(data):
    # Reject non-JSON constants (Python otherwise accepts NaN/Infinity).
    def reject(_):
        raise ValueError("Invalid JSON constant")
    return json.loads(data, parse_constant=reject)


class SocketClient:
    def __init__(self, path=DEFAULT_SOCKET, timeout=7):
        self.path = Path(path).expanduser()
        self.timeout = timeout

    def call(self, method, params):
        if method not in {"accounts", "list", "search", "get", "codes"}:
            raise ToolError("method_not_found")
        request_id = uuid.uuid4().hex
        frame = json.dumps({"version": 1, "id": request_id, "method": method,
                            "params": params}, ensure_ascii=False).encode("utf-8")
        if len(frame) > MAX_REQUEST:
            raise ToolError("too_large")
        try:
            parent, endpoint = self.path.parent.lstat(), self.path.lstat()
            if (not stat.S_ISDIR(parent.st_mode) or not stat.S_ISSOCK(endpoint.st_mode)
                    or parent.st_uid != os.geteuid() or endpoint.st_uid != os.geteuid()
                    or stat.S_IMODE(parent.st_mode) != 0o700
                    or stat.S_IMODE(endpoint.st_mode) != 0o600):
                raise ToolError("unauthorized")
            deadline = time.monotonic() + self.timeout
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(self.timeout)
                connection.connect(str(self.path))
                # macOS LOCAL_PEERCRED; Linux SO_PEERCRED supports synthetic CI tests.
                if sys.platform == "darwin":
                    import ctypes
                    libc = ctypes.CDLL(None, use_errno=True)
                    peer_uid, peer_gid = ctypes.c_uint(), ctypes.c_uint()
                    getpeereid = libc.getpeereid
                    getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
                    getpeereid.restype = ctypes.c_int
                    if getpeereid(connection.fileno(), ctypes.byref(peer_uid), ctypes.byref(peer_gid)) != 0:
                        raise ToolError("unauthorized")
                    uid = peer_uid.value
                elif hasattr(socket, "SO_PEERCRED"):
                    import struct
                    _, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                else:
                    raise ToolError("unauthorized")
                if uid != os.geteuid():
                    raise ToolError("unauthorized")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ToolError("timeout")
                connection.settimeout(remaining)
                connection.sendall(frame + b"\n")
                data = bytearray()
                while b"\n" not in data:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ToolError("timeout")
                    connection.settimeout(remaining)
                    chunk = connection.recv(min(8192, MAX_RESPONSE + 2 - len(data)))
                    if not chunk:
                        raise ToolError("unavailable")
                    data.extend(chunk)
                    if len(data.partition(b"\n")[0]) > MAX_RESPONSE:
                        raise ToolError("too_large")
                raw, _, trailing = data.partition(b"\n")
                if trailing:
                    raise ToolError("invalid_response")
            response = decode(raw.decode("utf-8"))
            if (not isinstance(response, dict) or type(response.get("version")) is not int
                    or response["version"] != 1 or response.get("id") != request_id
                    or ("result" in response) == ("error" in response)):
                raise ToolError("invalid_response")
            if "error" in response:
                error = response["error"]
                code = error.get("code") if isinstance(error, dict) else None
                raise ToolError(code if isinstance(code, str) and code in ERRORS else "invalid_response")
            result = response["result"]
            if not isinstance(result, dict) or result.get("contentTrust") != "untrusted":
                raise ToolError("invalid_response")
            capabilities = result.get("capabilities", [])
            if any(key in params for key in ("since", "status")) and (
                    not isinstance(capabilities, list) or "filters" not in capabilities):
                # Older v1 Apps ignore additive keys. Never silently broaden a filtered read.
                raise ToolError("unsupported_server")
            if method == "accounts" and not isinstance(result.get("accounts"), list):
                raise ToolError("unsupported_server")
            if method in {"list", "search"} and not isinstance(result.get("items"), list):
                raise ToolError("invalid_response")
            if method == "get" and (not isinstance(result.get("message"), dict) or not isinstance(result.get("text"), str)):
                raise ToolError("invalid_response")
            if method == "codes":
                if not isinstance(capabilities, list) or "codes" not in capabilities:
                    raise ToolError("unsupported_server")
                codes = result.get("codes")
                allowed = {"code", "fromName", "fromEmail", "date", "account", "messageID"}
                if not isinstance(codes, list) or any(
                        not isinstance(item, dict) or set(item) - allowed
                        or not all(isinstance(item.get(key), str) for key in ("code", "account", "messageID"))
                        or type(item.get("date")) is not int
                        or any(key in item and not isinstance(item[key], str) for key in ("fromName", "fromEmail"))
                        for item in codes) or set(result) - {"codes", "nextOffset", "contentTrust", "capabilities"}:
                    raise ToolError("invalid_response")
            return result
        except (TimeoutError, socket.timeout):
            raise ToolError("timeout") from None
        except (OSError, ValueError, UnicodeError, RecursionError):
            raise ToolError("unavailable") from None
