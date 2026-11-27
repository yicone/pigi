"""Direct-exec a real .app bundle without registering/activating the user's App."""
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import subprocess
import sys

scratch = Path(sys.argv[1]).resolve()
home = scratch / 'isolated home'
home.mkdir()
(home / 'Library/Preferences').mkdir(parents=True)
(scratch / 'tmp').mkdir()
real_home = Path(pwd.getpwuid(os.getuid()).pw_dir)

def quote(value):
    return json.dumps(str(value))

# No cfprefsd proxy to the real user's domain: Foundation must use this HOME.
# Deny real preferences, mailbox data and keychains for both reads and writes.
rules = ['(version 1)', '(allow default)', '(deny network*)',
         '(deny mach-lookup (global-name "com.apple.cfprefsd.agent") '
         '(global-name "com.apple.cfprefsd.daemon"))']
for relative in ('Library/Preferences', 'Library/Containers', 'Library/Keychains',
                 'Library/Application Support/pigi'):
    path = real_home / relative
    for protected in {path, path.resolve()}:
        rules.append('(deny file-read* file-write* (subpath ' + quote(protected) + '))')
profile = scratch / 'startup.sb'
profile.write_text('\n'.join(rules) + '\n')
env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
           TMPDIR=str(scratch / 'tmp'), PIGI_REGRESSION='1')

def bundle(identifier, name):
    app = scratch / (name + '.app')
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=identifier, CFBundleExecutable='probe', CFBundlePackageType='APPL')))
    binary = contents / 'MacOS/probe'
    shutil.copy2(scratch / 'probe', binary)
    subprocess.run(['codesign', '--sign', '-', str(app)], check=True, capture_output=True)
    return binary

app = bundle('one.yic.pigi', 'ProductionIdentifier')
other = bundle('one.yic.pigi.startup-regression', 'OtherIdentifier')
legacy = scratch / 'legacy.plist'
legacy.write_bytes(plistlib.dumps({
    'gmailAccounts': ['Legacy@Example.test'], 'gmailClientID': 'synthetic-client-id',
    'protonProxyMode': 'direct', 'translation.config': json.dumps({'model': 'legacy-model'}).encode(),
    'translation.privacy.v1': json.dumps({'accounts': {'legacy@example.test': {
        'enabled': True, 'protonConsent': False}}, 'services': []}).encode()}))
original = legacy.read_bytes()
for binary, mode in ((app, 'helper-startup'), (app, 'startup'), (app, 'startup'),
                     (other, 'standalone'), (scratch / 'probe', 'standalone')):
    result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile), str(binary), mode, str(legacy)],
                            env=env, text=True, capture_output=True, timeout=30)
    print(result.stdout, end='', flush=True)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(f'FAIL: {mode} exited {result.returncode}')
    if mode == 'helper-startup':
        assert not (home / 'Library/Application Support/pigi/mail.db').exists(), 'self-test must not migrate accounts'
db = home / 'Library/Application Support/pigi/mail.db'
assert db.is_file(), 'shared SQLite configuration must stay under the fixture HOME'
assert legacy.read_bytes() == original, 'legacy fixture must not be changed by migration'
print('PASS: same-ID startup/restart, injected legacy settings, migration and standalone shared configuration')
