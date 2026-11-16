"""Behaviour contract for ubuntu_os_update_cron.sh (stubbed externals only).

The wrapper is executed with a fake refresh script, a fake ``curl`` and a fake
``reboot`` on PATH, so no real host, network or reboot is involved.
"""
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WRAPPER = ROOT / 'ubuntu_os_update_cron.sh'
BASH = shutil.which('bash') or 'bash'


def posix(path):
    """MSYS bash only understands forward-slash paths on Windows."""
    return pathlib.Path(path).as_posix()

FAKE_REFRESH = """#!/usr/bin/env bash
printf 'fake refresh: %s\\n' "$*"
exit "${FAKE_REFRESH_RC:-0}"
"""

# curl stub: prints the configured API answer, remembers the arguments of every call.
FAKE_CURL = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "${FAKE_CURL_CALLS:?}"
if [[ "$*" == *"message_thread_id"* ]]; then
    printf '%s' "${FAKE_TG_BODY_THREAD:-$FAKE_TG_BODY}"
else
    printf '%s' "$FAKE_TG_BODY"
fi
"""

FAKE_REBOOT = """#!/usr/bin/env bash
printf 'reboot\\n' >> "${FAKE_REBOOT_MARKER:?}"
exit 0
"""


class CronWrapperTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = pathlib.Path(self._tmp.name)
        self.bin = self.dir / 'bin'
        self.bin.mkdir()
        self.logs = self.dir / 'log'
        self.calls = self.dir / 'curl-calls'
        self.reboot_marker = self.dir / 'rebooted'

        self.refresh = self.dir / 'ubuntu_os_update.sh'
        self.refresh.write_text(FAKE_REFRESH, encoding='utf-8', newline='\n')
        self._executable(self.refresh)
        self._stub('curl', FAKE_CURL)
        self._stub('reboot', FAKE_REBOOT)

        self.env_file = self.dir / 'ubuntu_os_update.env'
        self.env_file.write_text(
            'TELEGRAM_BOT_TOKEN=test-token\n'
            'TELEGRAM_CHAT_ID=test-chat\n'
            'TELEGRAM_THREAD_ID=1\n',
            encoding='utf-8', newline='\n')

    def _executable(self, path):
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def _stub(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding='utf-8', newline='\n')
        self._executable(path)

    def run_wrapper(self, *args, **env):
        full_env = {
            'PATH': f'{posix(self.bin)}:{os.environ.get("PATH", "")}',
            'FAKE_CURL_CALLS': posix(self.calls),
            'FAKE_TG_BODY': '{"ok":true}',
            'FAKE_REBOOT_MARKER': posix(self.reboot_marker),
            'HOME': posix(self.dir),
            'TMPDIR': posix(self.dir),
        }
        full_env.update({k: str(v) for k, v in env.items()})
        cmd = [BASH, posix(WRAPPER),
               '--host', 'home-server',
               '--env-file', posix(self.env_file),
               '--update-script', posix(self.refresh),
               '--log-dir', posix(self.logs),
               '--retry-delay', '1',
               '--attempts', '1',
               *args]
        return subprocess.run(cmd, env=full_env, text=True, capture_output=True, timeout=120)

    def log_text(self):
        log = self.logs / 'ubuntu_os_update_cron.log'
        return log.read_text(encoding='utf-8') if log.exists() else ''

    def curl_calls(self):
        return self.calls.read_text(encoding='utf-8') if self.calls.exists() else ''

    def rebooted(self):
        return self.reboot_marker.exists()

    def test_defaults_match_the_contract(self):
        source = WRAPPER.read_text(encoding='utf-8')
        self.assertIn('ATTEMPTS=3', source)
        self.assertIn('RETRY_DELAY=30', source)
        self.assertIn('message_thread_id', source)
        self.assertIn('REBOOT SKIPPED (notification not delivered)', source)

    def test_success_is_notified_then_one_reboot(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.rebooted(), 'the host must reboot after a confirmed delivery')
        self.assertEqual(self.reboot_marker.read_text(encoding='utf-8').count('reboot'), 1)
        log = self.log_text()
        self.assertIn('✅ home-server: обновление прошло успешно', log)
        self.assertIn('message_thread_id=1', self.curl_calls())

    def test_notification_failure_blocks_the_reboot(self):
        result = self.run_wrapper(FAKE_TG_BODY='{"ok":false,"description":"blocked"}')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.rebooted(), 'no delivery means no reboot')
        log = self.log_text()
        self.assertIn('REBOOT SKIPPED (notification not delivered)', log)
        self.assertIn('telegram: not delivered', log)

    def test_thread_fallback_delivers_without_a_topic(self):
        result = self.run_wrapper(
            FAKE_TG_BODY_THREAD='{"ok":false,"description":"wrong thread"}',
            FAKE_TG_BODY='{"ok":true}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.rebooted())
        self.assertIn('delivered without message_thread_id', self.log_text())

    def test_no_reboot_flag_keeps_the_host_up(self):
        result = self.run_wrapper('--no-reboot')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.rebooted())
        self.assertIn('REBOOT SKIPPED (--no-reboot)', self.log_text())
        self.assertIn('✅ home-server: обновление прошло успешно', self.log_text())

    def test_notify_only_skips_the_refresh_and_the_reboot(self):
        result = self.run_wrapper('--notify-only', '--no-reboot')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.rebooted())
        self.assertIn('notify-only: the OS refresh is skipped', self.log_text())

    def test_failed_refresh_is_reported_with_code_and_log_path(self):
        result = self.run_wrapper('--no-reboot', FAKE_REFRESH_RC='1')
        self.assertEqual(result.returncode, 1, result.stderr)
        log = self.log_text()
        self.assertIn('⚠️ home-server: надо разобраться (код 1, лог ', log)
        messages = [line.split('message: ', 1)[1] for line in log.splitlines() if 'message: ' in line]
        self.assertEqual(len(messages), 1, 'exactly one message is produced')
        self.assertLessEqual(len(messages[0].splitlines()), 2, 'the message must not exceed two lines')

    def test_failed_refresh_still_reboots_after_delivery(self):
        result = self.run_wrapper(FAKE_REFRESH_RC='1')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(self.rebooted())

    def test_missing_credentials_skip_the_reboot(self):
        self.env_file.write_text('TELEGRAM_BOT_TOKEN=\nTELEGRAM_CHAT_ID=\n', encoding='utf-8')
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(self.rebooted())
        self.assertIn('credentials are not configured', self.log_text())
        self.assertIn('REBOOT SKIPPED (notification not delivered)', self.log_text())

    def test_custom_updates_failure_is_reported_and_gates_the_result_code(self):
        hook = self.dir / 'host-custom-updates.sh'
        hook.write_text('#!/usr/bin/env bash\nexit 4\n', encoding='utf-8', newline='\n')
        self._executable(hook)
        result = self.run_wrapper('--no-reboot', '--custom-updates', posix(hook))
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('custom updates failed: 4', self.log_text())
        self.assertIn('код 4', self.log_text())

    def test_custom_updates_script_is_documented_as_the_host_only_step(self):
        source = WRAPPER.read_text(encoding='utf-8')
        self.assertIn('--custom-updates', source)
        self.assertIn('host-local updates script', source)

    def test_bad_usage_is_rejected(self):
        result = self.run_wrapper('--attempts', '9')
        self.assertEqual(result.returncode, 64)
        self.assertIn('--attempts', result.stderr)


if __name__ == '__main__':
    unittest.main()
