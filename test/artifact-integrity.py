#!/usr/bin/env python3
"""QA-139: real psyup dispatcher/handlers, fully controlled offline tool boundaries.

No installed compiler, wallet, config, or credentials are loaded. The fake dargo
models a compiler that leaves the previous output intact on failure. The CLI
only advertises structured results and records argv, then exits 42.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENTRY = Path(os.environ.get('PSYUP_TEST_ENTRY', ROOT / 'psyup'))
LIB = Path(os.environ.get('PSYUP_TEST_LIB', ROOT / 'lib'))


class ArtifactIntegrity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='qa139-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / 'bin').mkdir()
        (self.work / 'src').mkdir()
        (self.work / 'psy-home').mkdir()
        (self.work / 'Dargo.toml').write_text('name = "demo"\nentry = "src/main.psy"\n')
        (self.work / 'src/main.psy').write_text('#[contract]\npub struct Demo {}\n')
        self.cli_calls = self.work / 'cli-calls.txt'
        scripts = {
            'dargo': '''#!/bin/bash
set -eu
if [ "$1" = compile ]; then
    if /usr/bin/grep -q INVALID src/main.psy; then
        echo 'fixture compile error' >&2
        exit 1
    fi
    mkdir -p target
    printf '{"fixture":"original contract"}\\n' > target/demo.json
    if [ "${QA139_MUTATE_DURING_BUILD:-0}" = 1 ]; then
        printf '// edit during compile\\n' >> src/main.psy
    fi
elif [ "$1" = generate-abi ]; then
    [ ! -f FAIL_ABI ] || exit 7
    printf '{"fixture":"original ABI"}\\n' > target/demo.abi.json
else
    exit 90
fi
''',
            'psy_user_cli': '''#!/bin/bash
set -eu
if [ "$1" = --help ]; then
    printf 'fixture CLI supports --result-file\\n'
    exit 0
fi
printf '%s\\n' "$@" > "$QA139_CLI_CALLS"
exit 42
''',
            # Defensive guards: neither the controlled compiler nor CLI may network.
            'curl': '#!/bin/bash\nexit 91\n',
            'git': '#!/bin/bash\nexit 92\n',
        }
        for name, contents in scripts.items():
            path = self.work / 'bin' / name
            path.write_text(contents)
            path.chmod(0o755)
        self.env = {
            'PATH': f'{self.work / "bin"}:/usr/bin:/bin',
            'PSY_HOME': str(self.work / 'psy-home'),
            'PSYUP_LIB': str(LIB),
            'QA139_CLI_CALLS': str(self.cli_calls),
        }

    def run_psyup(self, *args):
        return subprocess.run(['/bin/bash', str(ENTRY), *args], cwd=self.work,
                              env=self.env, text=True, capture_output=True, timeout=10)

    def build(self):
        result = self.run_psyup('build')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def deploy(self, *args):
        # Explicit inert argv value satisfies helper resolution without any wallet.
        return self.run_psyup('deploy', '--private-key', 'QA_FIXTURE_NOT_A_KEY', *args)

    def test_failed_rebuild_must_block_automatic_previous_artifact(self):
        self.build()
        artifact = self.work / 'target/demo.json'
        previous = hashlib.sha256(artifact.read_bytes()).hexdigest()
        (self.work / 'src/main.psy').write_text('INVALID\n')
        failed = self.run_psyup('build')
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertEqual(hashlib.sha256(artifact.read_bytes()).hexdigest(), previous)
        result = self.deploy()
        observed = self.cli_calls.read_text() if self.cli_calls.exists() else ''
        self.assertFalse(self.cli_calls.exists(),
                         f'stale automatic artifact reached CLI; exit={result.returncode}; '
                         f'argv={observed!r}; output={result.stdout + result.stderr!r}')
        self.assertNotEqual(result.returncode, 0)

    def test_current_successful_build_reaches_controlled_cli(self):
        self.build()
        result = self.deploy()
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn('target/demo.json', self.cli_calls.read_text())
        self.assertTrue((self.work / '.psy-build-manifest').is_file())

    def test_missing_artifact_blocks_without_cli_invocation(self):
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.cli_calls.exists())
        self.assertIn('compiled artifact not found', result.stderr)

    def test_explicit_artifact_is_a_separate_user_selected_path(self):
        (self.work / 'explicit.json').write_text(json.dumps({'fixture': 'explicit'}))
        result = self.deploy('--contract-path', 'explicit.json')
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn('explicit.json', self.cli_calls.read_text())


    def assert_auto_blocked(self):
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.cli_calls.exists(), result.stdout + result.stderr)
        self.assertIn("run 'psyup build'", result.stderr)

    def test_edit_without_build_blocks_automatic_deploy(self):
        self.build()
        original_time = (self.work / 'src/main.psy').stat().st_mtime_ns
        with (self.work / 'src/main.psy').open('a') as source:
            source.write('// edited source\n')
        os.utime(self.work / 'src/main.psy', ns=(original_time, original_time))
        self.assert_auto_blocked()

    def test_source_set_addition_and_removal_are_bound(self):
        for change in ['add', 'remove']:
            with self.subTest(change=change):
                self.build()
                extra = self.work / 'src/extra.psy'
                if change == 'add':
                    extra.write_text('// new source\n')
                else:
                    extra.unlink()
                self.assert_auto_blocked()

    def test_manifest_lock_and_artifact_contents_are_bound(self):
        for filename in ['Dargo.toml', 'Dargo.lock', 'target/demo.json']:
            with self.subTest(filename=filename):
                self.build()
                with (self.work / filename).open('a') as file:
                    file.write('// changed contents\n')
                self.assert_auto_blocked()

    def test_missing_freshness_record_blocks_legacy_artifact(self):
        self.build()
        (self.work / '.psy-build-manifest').unlink()
        self.assert_auto_blocked()

    def test_abi_generation_failure_invalidates_the_previous_record(self):
        self.build()
        (self.work / 'FAIL_ABI').touch()
        result = self.run_psyup('build')
        self.assertEqual(result.returncode, 7)
        self.assertFalse((self.work / '.psy-build-manifest').exists())
        self.assert_auto_blocked()

    def test_custom_entry_build_does_not_certify_the_default_artifact(self):
        self.build()
        result = self.run_psyup('build', '--entry-path', 'src/main.psy')
        self.assertEqual(result.returncode, 0)
        self.assert_auto_blocked()
        explicit = self.deploy('--contract-path', 'target/demo.json')
        self.assertEqual(explicit.returncode, 42)

    def test_edit_during_compilation_does_not_certify_its_artifact(self):
        self.env['QA139_MUTATE_DURING_BUILD'] = '1'
        self.build()
        self.assertFalse((self.work / '.psy-build-manifest').exists())
        self.assert_auto_blocked()

    def test_ignored_generated_files_do_not_invalidate_success(self):
        self.build()
        (self.work / 'target/generated.psy').write_text('// generated\n')
        result = self.deploy()
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)

    @unittest.skipUnless(os.environ.get('PSYUP_TEST_TEMPLATE'), 'set PSYUP_TEST_TEMPLATE for real template positive control')
    def test_real_default_template_contract_root_can_build_and_auto_deploy(self):
        import shutil
        template = Path(os.environ['PSYUP_TEST_TEMPLATE'])
        shutil.copyfile(template / 'Dargo.toml', self.work / 'Dargo.toml')
        shutil.copytree(template / 'src', self.work / 'src', dirs_exist_ok=True)
        # Package rename is the same manifest change cmd_new applies; the
        # real contract template content and dependencies remain intact.
        manifest = (self.work / 'Dargo.toml').read_text()
        import re
        manifest = re.sub(r'(?m)^name\s*=\s*"[^"]*"', 'name = "demo"', manifest)
        (self.work / 'Dargo.toml').write_text(manifest)
        self.build()
        self.assertTrue((self.work / '.psy-build-manifest').is_file())
        result = self.deploy()
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn('target/demo.json', self.cli_calls.read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
