# CI and local tests must not depend on, or modify, the logged-in user's app data.
# Source this from a regression script. It records the whole real
# Application Support/pigi directory (every entry plus the directory itself)
# and any Containers copy, then checks that tree was not created or rewritten.
#
# A live pigi process rewrites mail.db-wal and atomically replaces
# mail-headers.json, which also changes the parent directory mtime. An old
# regression on the self-hosted runner opens the default translations.db.
# Stop both and confirm lsof shows no opener before treating a diff as a test bug.
#
# Scripts that execute the production support-directory path must also run the
# binary with isolate_support_env so CFFIXED_USER_HOME and HOME point at a temp directory.
# Do not delete the user's real database from here. Do not use immutable=1 to
# decide that translations.db is empty; that flag ignores committed WAL frames.

isolate_support_snapshot() {
  ISOLATE_REAL_HOME="$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
  ISOLATE_SNAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pigi-support-snap.XXXXXX")"
  _isolate_support_record "$ISOLATE_SNAP_DIR/before"
}

# Usage: isolate_support_env "$temp_home" -- command args...
isolate_support_env() {
  local home="$1"
  shift
  if [[ "${1:-}" == "--" ]]; then shift; fi
  mkdir -p "$home"
  PIGI_REGRESSION=1 CFFIXED_USER_HOME="$home" HOME="$home" "$@"
}

isolate_support_unchanged() {
  _isolate_support_record "$ISOLATE_SNAP_DIR/after"
  cmp -s "$ISOLATE_SNAP_DIR/before" "$ISOLATE_SNAP_DIR/after"
}

isolate_support_finish() {
  local status=$?
  if [[ -n "${ISOLATE_SNAP_DIR:-}" ]]; then
    if ! isolate_support_unchanged; then
      echo "FAIL: real Application Support/pigi or a Containers copy was created or modified" >&2
      diff -u "$ISOLATE_SNAP_DIR/before" "$ISOLATE_SNAP_DIR/after" >&2 || true
      status=1
    fi
    rm -rf "$ISOLATE_SNAP_DIR"
    unset ISOLATE_SNAP_DIR
  fi
  if [[ -n "${TEST_BUILD:-}" ]]; then rm -rf "$TEST_BUILD"; fi
  exit "$status"
}

_isolate_support_record() {
  python3 - "$ISOLATE_REAL_HOME" "$1" <<'PY'
import os, pathlib, stat, sys
home = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
lines = []

def record(path: pathlib.Path) -> None:
    try:
        st = path.lstat()
    except FileNotFoundError:
        lines.append(f"ABSENT\t{path}")
        return
    if stat.S_ISLNK(st.st_mode):
        kind = "LNK"
    elif stat.S_ISDIR(st.st_mode):
        kind = "DIR"
    else:
        kind = "FILE"
    lines.append(f"{kind}\t{path}\t{st.st_mtime_ns}\t{st.st_size}\t{st.st_ino}")

def tree(root: pathlib.Path) -> None:
    record(root)
    if not root.exists() or root.is_symlink() or not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        filenames.sort()
        base = pathlib.Path(dirpath)
        for name in dirnames:
            record(base / name)
        for name in filenames:
            record(base / name)

tree(home / "Library/Application Support/pigi")
containers = home / "Library/Containers"
needle = pathlib.Path("Data/Library/Application Support/pigi")
if containers.is_dir() and not containers.is_symlink():
    matches = sorted(path for path in containers.glob("*") if (path / needle).exists())
    if matches:
        for path in matches:
            tree(path / needle)
    else:
        lines.append(f"ABSENT\t{containers}/<bundle>/Data/Library/Application Support/pigi")
else:
    lines.append(f"ABSENT\t{containers}")
out.write_text("\n".join(lines) + "\n")
PY
}
