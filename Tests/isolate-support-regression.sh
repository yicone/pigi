#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# This harness intentionally stays outside the sandbox so it can simulate an
# unrelated writer. Each tested command is sandboxed; all writes use fixtures.
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/Tests/isolate_support_regression.py"
