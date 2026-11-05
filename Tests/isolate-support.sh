# CI and local tests must not depend on, or modify, the logged-in user's app data.
# Source this from a regression script. It records translations.db (and -wal/-shm)
# under the real passwd home — Application Support/pigi and any Containers copy —
# then checks those files were not created or rewritten.
#
# Scripts that execute the production support-directory path must also run the
# binary with isolate_support_env so CFFIXED_USER_HOME and HOME point at a temp directory.
# Do not delete the user's real database from here.

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
      echo "FAIL: real Application Support/pigi or Containers translations.db was created or modified" >&2
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
import pathlib, sys
home = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
names = ("translations.db", "translations.db-wal", "translations.db-shm")
lines = []

def record(path: pathlib.Path) -> None:
    if path.is_symlink() or path.exists():
        st = path.lstat()
        lines.append(f"FILE\t{path}\t{st.st_mtime_ns}\t{st.st_size}\t{st.st_ino}")
    else:
        lines.append(f"ABSENT\t{path}")

support = home / "Library/Application Support/pigi"
for name in names:
    record(support / name)
containers = home / "Library/Containers"
if containers.is_dir():
    matches = sorted(containers.glob("*/Data/Library/Application Support/pigi/translations.db*"))
    if matches:
        for path in matches:
            record(path)
    else:
        lines.append(f"ABSENT\t{containers}")
else:
    lines.append(f"ABSENT\t{containers}")
out.write_text("\n".join(lines) + "\n")
PY
}
