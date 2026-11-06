# Source from a regression script, then call isolate_support_begin "$0" "$@"
# BEFORE creating fixtures or installing traps. The whole script (including
# Python/Go/Swift children) runs under an inherited macOS write-deny sandbox.
# An already running pigi/runner is outside that sandbox and may sync normally.
# AppSupport's PIGI_REGRESSION/XCTest checks remain a separate defense.
#
# sandbox-exec is deprecated, but still ships on supported macOS. Fail closed
# if unavailable or ineffective; never fall back to observing global mtimes.
# HOME redirection alone is not a security boundary. Resolve the passwd home,
# independent of HOME/CFFIXED_USER_HOME, and protect Containers as AppSupport does.

isolate_support_begin() {
  if [[ "${PIGI_ISOLATE_PID:-}" == "$$" ]]; then
    # This also prevents an accidentally inherited/spoofed marker from silently
    # skipping isolation. No writes to real user data are used as a self-test.
    python3 - "${PIGI_ISOLATE_PROBE:?missing sandbox probe}" <<'PY'
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except OSError as error:
    if error.errno != errno.EPERM:
        raise
else:
    os.close(fd)
    raise SystemExit("FAIL: user-data write sandbox is not active")
PY
    return
  fi
  _isolate_support_run /bin/bash -c \
    'export PIGI_ISOLATE_PID=$$; exec /bin/bash "$@"' bash "$@"
  exit $?
}

# Swift's macro server otherwise attempts a nested sandbox_apply, rejected by
# Seatbelt inside our sandbox. It still inherits OUR write-deny policy, as does
# swiftc itself. Keep this option confined to these guarded regression builds.
isolate_support_swiftc() {
  xcrun swiftc -disable-sandbox "$@"
}

# Usage: isolate_support_env "$temp_home" -- command args...
isolate_support_env() {
  local test_home="$1"
  shift
  if [[ "${1:-}" == "--" ]]; then shift; fi
  mkdir -p "$test_home"
  PIGI_REGRESSION=1 CFFIXED_USER_HOME="$test_home" HOME="$test_home" "$@"
}

isolate_support_finish() {
  local status=$?
  if [[ -n "${TEST_BUILD:-}" ]]; then rm -rf "$TEST_BUILD"; fi
  exit "$status"
}

_isolate_support_run() (
  set -euo pipefail
  if [[ ! -x /usr/bin/sandbox-exec ]]; then
    echo 'FAIL: sandbox-exec is required for user-data write isolation' >&2
    exit 1
  fi
  local guard_dir
  guard_dir="$(mktemp -d "${TMPDIR:-/tmp}/pigi-support-guard.XXXXXX")"
  trap 'rm -rf "$guard_dir"' EXIT
  guard_dir="$(cd "$guard_dir" && pwd -P)"
  # This setup process is outside the sandbox. The child startup probes only
  # this disposable fixture; production deny rules kill the offending process.
  python3 "$(dirname "${BASH_SOURCE[0]}")/support_sandbox.py" "$guard_dir"
  export PIGI_ISOLATE_PROBE="$guard_dir/write-probe"
  local status=0
  /usr/bin/sandbox-exec -f "$guard_dir/profile.sb" "$@" || status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "FAIL: isolated command exited $status (real pigi/Containers writes are forbidden)" >&2
  fi
  exit "$status"
)

# Also usable as a command wrapper, e.g.:
# bash Tests/isolate-support.sh swift test --disable-sandbox -Xswiftc -disable-sandbox
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _isolate_support_run "$@"
fi
