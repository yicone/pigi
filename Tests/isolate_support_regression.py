"""Exercise the kernel guard with disposable data, never writing real pigi data."""
import os
from pathlib import Path
import subprocess
import shlex
import tempfile
import sys
import time
import unittest

from support_sandbox import profile

ROOT = Path(__file__).resolve().parent.parent
WRAPPER = ROOT / 'Tests/isolate-support.sh'


class SupportIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pigi-isolation.')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / 'home with "quotes"'
        self.support = self.home / 'Library/Application Support/pigi'
        self.container = self.home / 'Library/Containers/one.yic.pigi/Data/Library/Application Support/pigi'
        for path in (self.support, self.container):
            path.mkdir(parents=True)
            (path / 'existing').write_bytes(b'original')
        self.guard = self.base / 'profile.sb'
        self.guard.write_text(profile(self.base, self.home))

    def run_guarded(self, *args):
        return subprocess.run(['/usr/bin/sandbox-exec', '-f', str(self.guard), *map(str, args)],
                              capture_output=True, text=True, timeout=30)

    def test_writes_and_descendants_fail_without_mutation(self):
        for root in (self.support, self.container):
            original_mode = (root / 'existing').stat().st_mode & 0o777
            commands = [
                ['/usr/bin/touch', root / 'new'],
                ['/bin/bash', '-c', 'echo corrupt >> "$1"', 'probe', root / 'existing'],
                ['/bin/rm', root / 'existing'],
                ['/bin/mv', root / 'existing', self.base / 'moved'],
                ['/bin/mkdir', root / 'new-directory'],
                ['/bin/chmod', '777', root / 'existing'],
                # A Python launcher cannot bypass the inherited sandbox.
                ['python3', '-c', 'import subprocess,sys; sys.exit(subprocess.call(["/usr/bin/touch",sys.argv[1]]))', root / 'new'],
            ]
            for command in commands:
                with self.subTest(command=command):
                    result = self.run_guarded(*command)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((root / 'existing').read_bytes(), b'original')
                    self.assertEqual(sorted(p.name for p in root.iterdir()), ['existing'])
            self.assertEqual((root / 'existing').stat().st_mode & 0o777, original_mode)

    def test_absent_support_and_new_container_are_protected(self):
        for path in (self.support, self.container):
            (path / 'existing').unlink()
            path.rmdir()
        self.guard.write_text(profile(self.base, self.home))
        for path in (self.support, self.home / 'Library/Containers/new.bundle/Data/Library/Application Support/pigi'):
            result = self.run_guarded('/bin/mkdir', '-p', path)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(path.exists())

    def test_symlink_destinations_and_aliases_are_protected(self):
        outside = self.base / 'external-data'
        outside.mkdir()
        (self.support / 'linked').symlink_to(outside, target_is_directory=True)
        alias = self.base / 'alias'
        alias.symlink_to(self.support, target_is_directory=True)
        self.guard.write_text(profile(self.base, self.home))
        for path in (outside / 'probe', self.support / 'linked/probe', alias / 'probe'):
            self.assertNotEqual(self.run_guarded('/usr/bin/touch', path).returncode, 0)
            self.assertFalse(path.exists())

    def test_external_concurrent_writer_is_unaffected(self):
        # The writer is launched by this unsandboxed parent before the guarded
        # reader starts. The handshake guarantees writes during the test window.
        writer = subprocess.Popen(['python3', '-c',
            'import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); roots=sys.argv[2:]; '
            '\nwhile not (p/"reader-ready").exists(): time.sleep(.001)\n'
            'for _ in range(100):\n'
            ' for root in roots:\n'
            '  with (pathlib.Path(root)/"existing").open("a") as stream: stream.write("sync\\n")\n'
            '(p/"writer-done").touch()', str(self.base), str(self.support), str(self.container)])
        try:
            result = self.run_guarded('python3', '-c',
                'import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); (p/"reader-ready").touch(); '
                '\nwhile not (p/"writer-done").exists(): time.sleep(.001)\n'
                '(p/"allowed-output").write_text("ok")', self.base)
            self.assertEqual(writer.wait(timeout=5), 0)
        finally:
            if writer.poll() is None:
                writer.terminate()
                writer.wait(timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.support / 'existing').read_text().count('sync\n'), 100)
        self.assertEqual((self.base / 'allowed-output').read_text(), 'ok')

    def test_wrapper_status_arguments_home_and_cleanup(self):
        env = dict(os.environ, TMPDIR=str(self.base))
        script = self.base / 'script.sh'
        script.write_text('set -euo pipefail\nsource "$1"\nisolate_support_begin "$0" "$@"\n'
                          'shift\nTEST_BUILD="$(mktemp -d)"\ntrap isolate_support_finish EXIT\n'
                          'isolate_support_env "$TEST_BUILD/home" -- /bin/bash -c '
                          "'[[ $HOME == $CFFIXED_USER_HOME && $PIGI_REGRESSION == 1 ]]'\n"
                          '[[ "$1" == "argument with spaces" ]]\nexit "$2"\n')
        for status in (0, 23):
            result = subprocess.run(['/bin/bash', str(script), str(WRAPPER), 'argument with spaces', str(status)],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertEqual(list(self.base.glob('pigi-support-guard.*')), [])
            self.assertEqual(list(self.base.glob('tmp.*')), [])

    def test_spoofed_reentry_fails_closed(self):
        script = self.base / 'spoof.sh'
        script.write_text('set -euo pipefail\nsource "$1"\nPIGI_ISOLATE_PID=$$\n'
                          'PIGI_ISOLATE_PROBE="$2/probe"\nisolate_support_begin "$0" "$@"\nexit 0\n')
        result = subprocess.run(['/bin/bash', str(script), str(WRAPPER), str(self.base)],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('sandbox is not active', result.stderr)

    def test_each_caller_rejects_injected_write(self):
        for caller in sorted((ROOT / 'Tests').glob('*-regression.sh')):
            text = caller.read_text()
            if 'source "$ROOT/Tests/isolate-support.sh"' not in text:
                continue
            for target in (self.support, self.container):
                # Copy only into this test's temp directory. Fix ROOT so the
                # original entry sequence can re-exec unchanged from there.
                lines = text.splitlines()
                lines = [('ROOT=' + shlex.quote(str(ROOT))) if line.startswith('ROOT=') else line for line in lines]
                index = lines.index('isolate_support_begin "$0" "$@"') + 1
                lines.insert(index, '/usr/bin/touch ' + shlex.quote(str(target / 'injected')))
                script = self.base / caller.name
                script.write_text('\n'.join(lines) + '\n')
                with self.subTest(caller=caller.name, target=target):
                    result = subprocess.run(['/bin/bash', str(script)],
                        env=dict(os.environ, PIGI_ISOLATE_EXTRA_HOME=str(self.home)),
                        capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 137, result.stderr)
                    self.assertNotIn('sandbox_apply', result.stderr)
                    self.assertFalse((target / 'injected').exists())
                    self.assertEqual((target / 'existing').read_bytes(), b'original')

    def test_production_profile_denies_real_roots_without_writing(self):
        # sandbox_check is a permission query only. Existing paths are needed:
        # macOS reports denial for nonexistent paths even without a sandbox.
        code = """
import ctypes, os, pathlib, pwd, tempfile
lib = ctypes.CDLL('/usr/lib/libsandbox.dylib')
check = lib.sandbox_check
# The path is variadic (on arm64 it must not be declared a fixed argument).
check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
check.restype = ctypes.c_int
home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
for root in (home / 'Library/Application Support/pigi', home / 'Library/Containers'):
    if root.exists():
        assert check(os.getpid(), b'file-write-data', 1, str(root.resolve()).encode()) == 1
with tempfile.TemporaryDirectory() as scratch:
    assert check(os.getpid(), b'file-write-data', 1, str(pathlib.Path(scratch).resolve()).encode()) == 0
"""
        result = subprocess.run(['/bin/bash', str(WRAPPER), 'python3', '-c', code],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_macro_compilation_inherits_write_guard(self):
        source = self.base / 'MacroProbe.swift'
        source.write_text("""import Foundation
import Observation
@Observable final class Counter { var value = 42 }
@main struct Probe {
    static func main() throws {
        precondition(Counter().value == 42)
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
""")
        script = self.base / 'compile-probe.sh'
        script.write_text('set -euo pipefail\nsource "$1"\nisolate_support_begin "$0" "$@"\n'
                          'isolate_support_swiftc -parse-as-library "$2" -o "$3"\n'
                          'echo "compiled macro inside guard"\n"$3" "$4"\n')
        binary = self.base / 'macro-probe'
        result = subprocess.run(['/bin/bash', str(script), str(WRAPPER), str(source), str(binary),
                                 str(self.support / 'existing')],
                                env=dict(os.environ, PIGI_ISOLATE_EXTRA_HOME=str(self.home)),
                                capture_output=True, text=True, timeout=60)
        self.assertIn('compiled macro inside guard', result.stdout, result.stderr)
        self.assertEqual(result.returncode, 137, result.stderr)
        self.assertEqual((self.support / 'existing').read_bytes(), b'original')

    def test_all_callers_enter_before_fixtures(self):
        callers = []
        for path in (ROOT / 'Tests').glob('*-regression.sh'):
            text = path.read_text()
            if 'source "$ROOT/Tests/isolate-support.sh"' in text:
                callers.append(path.name)
                self.assertIn('isolate_support_begin "$0" "$@"', text)
                self.assertLess(text.index('isolate_support_begin'), text.index('mktemp'))
                self.assertNotIn('isolate_support_snapshot', text)
        self.assertEqual(len(callers), 8)


def run_all_callers_with_external_writer():
    """Opt-in full suite: --all-callers; each original script runs only once."""
    with tempfile.TemporaryDirectory(prefix='pigi-concurrent-regressions.') as temp:
        scratch = Path(temp).resolve()
        home = scratch / 'simulated-user'
        roots = [home / 'Library/Application Support/pigi',
                 home / 'Library/Containers/one.yic.pigi/Data/Library/Application Support/pigi']
        for root in roots:
            root.mkdir(parents=True)
        # This independent process is deliberately outside every test sandbox.
        writer = subprocess.Popen(['python3', '-c', """
import pathlib, sys, time
scratch = pathlib.Path(sys.argv[1]); roots = [pathlib.Path(p) for p in sys.argv[2:]]
while not (scratch / 'stop').exists():
    for root in roots:
        with (root / 'mail.db-wal').open('a') as stream: stream.write('synthetic sync\\n')
        (root / 'mail-headers.json').write_text('synthetic')
    time.sleep(.01)
""", str(scratch), *map(str, roots)])
        failures = []
        seen = 0
        try:
            for caller in sorted((ROOT / 'Tests').glob('*-regression.sh')):
                if 'source "$ROOT/Tests/isolate-support.sh"' not in caller.read_text():
                    continue
                seen += 1
                before = (roots[0] / 'mail.db-wal').stat().st_size if (roots[0] / 'mail.db-wal').exists() else 0
                started = time.monotonic()
                log = scratch / (caller.stem + '.log')
                with log.open('w') as output:
                    result = subprocess.run(['/bin/bash', str(caller)], cwd=ROOT,
                        env=dict(os.environ, PIGI_ISOLATE_EXTRA_HOME=str(home)),
                        stdout=output, stderr=subprocess.STDOUT, timeout=1200)
                after = (roots[0] / 'mail.db-wal').stat().st_size
                print(f'{caller.name}: exit={result.returncode}, external WAL bytes +{after - before}, '
                      f'{time.monotonic() - started:.1f}s', flush=True)
                if result.returncode or after <= before or writer.poll() is not None:
                    failures.append(caller.name)
                    print(log.read_text(), flush=True)
        finally:
            (scratch / 'stop').touch()
            try:
                writer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                writer.terminate()
                writer.wait(timeout=5)
        if seen != 8:
            failures.append(f'expected 8 callers, found {seen}')
        if failures:
            raise SystemExit('FAILED: ' + ', '.join(failures))


if __name__ == '__main__':
    if sys.argv[1:] == ['--all-callers']:
        run_all_callers_with_external_writer()
    else:
        unittest.main(verbosity=2)
