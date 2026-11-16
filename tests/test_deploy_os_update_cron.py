"""Contract checks for deploy_os_update_cron.sh (the Kali deployment path).

The deployment script must be repeatable: it refuses to write when the host
timezone does not match the declared schedule, compares sha256 before every
write, removes the declared legacy jobs, never enables --release-upgrade and
reads the result back. The live idempotency proof (changed=0 on the second run)
is produced against the host itself; these tests keep the contract in the repo.
"""
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEPLOY = ROOT / 'deploy_os_update_cron.sh'
BASH = shutil.which('bash') or 'bash'


class DeployScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = DEPLOY.read_text(encoding='utf-8')

    def test_script_parses_and_rejects_bad_usage(self):
        self.assertEqual(subprocess.run([BASH, '-n', str(DEPLOY)], capture_output=True).returncode, 0)
        result = subprocess.run([BASH, str(DEPLOY)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 64)
        self.assertIn('--address is required', result.stderr)

    def test_declares_the_owner_schedule_and_the_kali_rule(self):
        self.assertIn('CRON_SPEC="0 5 * * 0"', self.text)
        self.assertIn('EXPECTED_TZ="+0500"', self.text)
        self.assertIn('--release-upgrade', self.text)
        self.assertIn('Kali must not run the rolling dist-upgrade', self.text)

    def test_timezone_is_asserted_before_any_write(self):
        read_tz = self.text.index('host_tz=$(remote')
        assert_tz = self.text.index('[[ $host_tz == "$EXPECTED_TZ" ]]')
        first_write = self.text.index('install_file "$SOURCE_DIR/ubuntu_os_update.sh"')
        self.assertLess(read_tz, assert_tz)
        self.assertLess(assert_tz, first_write)

    def test_every_write_is_guarded_by_a_sha256_comparison(self):
        install = self.text[self.text.index('install_file() {'):self.text.index('# --- Telegram credentials')]
        self.assertIn('sha256sum', install)
        self.assertIn('return 1', install)
        self.assertIn('install -m', install)
        self.assertEqual(self.text.count('install_file "$'), 4)

    def test_credentials_are_never_printed(self):
        self.assertIn('chmod 600', self.text)
        self.assertEqual(self.text.count('"$token"'), 1, 'the token value is used once, to build the env file')
        block = self.text[self.text.index('printf \'TELEGRAM_BOT_TOKEN='):]
        self.assertIn('ubuntu_os_update.env', block.splitlines()[2])

    def test_legacy_jobs_are_removed_and_the_result_is_read_back(self):
        self.assertIn('--legacy-job', self.text)
        self.assertIn('sudo rm -f $job', self.text)
        self.assertIn('sudo cat $CRON_FILE', self.text)
        self.assertIn('crontab -l -u root', self.text)
        self.assertIn('another weekly update job is still installed', self.text)
        self.assertIn('changed=%d failed=0', self.text)


if __name__ == '__main__':
    unittest.main()
