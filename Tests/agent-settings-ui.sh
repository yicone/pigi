#!/bin/bash
# Standalone synthetic UI, never the production App. No dependency installs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tests/isolate-support.sh"
TEST_BUILD="$(mktemp -d /tmp/pigi-agent-settings.XXXXXX)"
trap isolate_support_finish EXIT
mkdir -p "$TEST_BUILD/home"

# Runtime profile generation uses passwd metadata, without opening a real DB/keychain.
# Deny the ENTIRE real home, system keychains, network and securityd; probe a synthetic canary.
python3 - "$TEST_BUILD" "${1:---test}" <<'PY'
import json, pathlib, pwd, os, sys
root = pathlib.Path(sys.argv[1]).resolve()
home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
assert home != root and home not in root.parents
canary = root / 'blocked-canary'
canary.write_text('synthetic guard probe')
q = lambda s: json.dumps(str(s))
profile = ['(version 1)', '(allow default)',
           '(deny mach-lookup (global-name "com.apple.securityd"))']
if sys.argv[2] in ('--peer-server', '--peer-smoke'):
    # Only the synthetic AF_UNIX endpoint is needed; all IP networking stays denied.
    profile += ['(deny network-outbound (remote ip "*:*"))', '(deny network-inbound (local ip "*:*"))']
else:
    profile += ['(deny network*)']
for path in (home, pathlib.Path('/Library/Keychains'), canary):
    profile.append('(deny file-read* file-write* (subpath ' + q(path) + '))')
(root / 'runtime.sb').write_text('\n'.join(profile) + '\n')
(root / 'protected-home').write_text(str(home))
PY
cp "$ROOT/Tests/agent-peer-probe.py" "$TEST_BUILD/agent-peer-probe.py"

SOURCES=()
while IFS= read -r source; do
    case "$source" in */Keychain.swift) ;; *) SOURCES+=("$source") ;; esac
done < <(find "$ROOT/Sources/PigiCore" -name '*.swift' | sort)
bash "$ROOT/Tests/isolate-support.sh" xcrun swiftc -disable-sandbox -swift-version 5 -D PIGI_REGRESSION -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" "$ROOT/Pigi/PageHeader.swift" "$ROOT/Pigi/AgentSettingsPage.swift" \
    "$ROOT/Tests/AgentSettingsUI.swift" -lsqlite3 -lz \
    -o "$TEST_BUILD/pigi-agent-settings-fixture"

# Both automatic and manual modes run the same in-process isolation proofs BEFORE NSApplication.
status=0
isolate_support_env "$TEST_BUILD/home" -- /usr/bin/sandbox-exec -f "$TEST_BUILD/runtime.sb" \
    "$TEST_BUILD/pigi-agent-settings-fixture" "$TEST_BUILD" "${1:---test}" || status=$?
exit "$status"
