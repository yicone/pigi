"""Generate the regression write guard. No HOME/environment override of passwd home."""
import os
from pathlib import Path
import pwd
import sys


def profile(scratch: Path, home: Path, additional_homes=()) -> str:
    roots = []
    for protected_home in (home, *additional_homes):
        roots.extend([protected_home / "Library/Application Support/pigi", protected_home / "Library/Containers"])
    # Seatbelt matches canonical paths. Also cover lexical paths and existing
    # symlink destinations, without following symlink loops while traversing.
    protected = {str(root) for root in roots} | {str(root.resolve()) for root in roots}
    # Only inspect pigi data for symlink escapes, not other apps' containers.
    data_roots = []
    for index in range(0, len(roots), 2):
        data_roots.append(roots[index])
        data_roots.extend(roots[index + 1].glob('*/Data/Library/Application Support/pigi'))
    for root in data_roots:
        protected.update((str(root), str(root.resolve())))
        if root.is_dir():
            for base, dirs, files in os.walk(root, followlinks=False):
                for name in dirs + files:
                    path = Path(base) / name
                    if path.is_symlink():
                        protected.add(str(path.resolve()))

    def quote(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

    rules = ['(version 1)', '(allow default)']
    for path in sorted(protected):
        rules.append('(deny file-write* (with send-signal SIGKILL) (subpath ' + quote(path) + '))')
    rules.append('(deny file-write* (literal ' + quote(str(scratch / 'write-probe')) + '))')
    return '\n'.join(rules) + '\n'


if __name__ == '__main__':
    scratch = Path(sys.argv[1]).resolve()
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    # Test-only fixture coverage is additive. It can never replace/remove the
    # passwd-home rules, even if HOME/CFFIXED_USER_HOME have been redirected.
    extra = os.environ.get('PIGI_ISOLATE_EXTRA_HOME')
    additional = (Path(extra).resolve(),) if extra else ()
    (scratch / 'profile.sb').write_text(profile(scratch, home, additional))
