"""Safe local regression tests; never execute main() or real systemctl/userdel."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install-snell.sh"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.conf = self.root / "snell"
        self.conf.mkdir()
        self.binary = self.root / "snell-server"
        self.binary.write_text("old-valid-binary\n")
        self.unit = self.root / "snell.service"
        self.unit.write_text("old-service\n")
        self.config = self.conf / "snell-server.conf"
        self.config.write_text("[snell-server]\nlisten = 0.0.0.0:32568\npsk = test-only-key\nipv6 = false\n")
        self.proxy = self.conf / "surge-proxy.txt"
        self.proxy.write_text("old-node\n")
        self.source = self.root / "new-binary"
        self.source.write_text("new-invalid-binary\n")
        # Only function definitions. All privileged absolute locations are redirected.
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        source = source.replace("readonly BIN=/usr/local/bin/snell-server", 'readonly BIN="$TEST_ROOT/snell-server"')
        source = source.replace("readonly CONF_DIR=/etc/snell", 'readonly CONF_DIR="$TEST_ROOT/snell"')
        source = source.replace("readonly UNIT=/etc/systemd/system/snell.service", 'readonly UNIT="$TEST_ROOT/snell.service"')
        source = source.replace("/var/backups/snell", self.temp.name + "/backups")
        self.definitions = source + r'''
systemctl() {
    printf '%s\n' "$*" >> "$TEST_ROOT/systemctl.log"
    case "$1" in
        show)
            case "$*" in
                *LoadState*) echo "${MOCK_LOAD_STATE:-loaded}" ;;
                *ExecStart*) printf '{ path=%s ; argv[]=%s -c %s ; }\n' "${MOCK_BINARY_PATH:-$BIN}" "$BIN" "${MOCK_CONFIG_PATH:-$CONF_DIR/snell-server.conf}" ;;
            esac ;;
        is-enabled) echo enabled ;;
        start) ! grep -q 'invalid' "$BIN" ;;
        cat) printf 'effective service\n' ;;
        *) return 0 ;;
    esac
}
userdel() { printf '%s\n' "$*" >> "$TEST_ROOT/userdel.log"; }
if [[ $(uname -s) == Darwin ]]; then
    file_identity() { stat -f '%d:%i' "$1"; }
fi
'''

    def run_shell(self, commands, expect=0):
        result = subprocess.run(
            ["bash", "-c", self.definitions + commands],
            env=dict(os.environ, TEST_ROOT=str(self.root)),
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return result

    def test_reinstall_preserves_config(self):
        original = self.config.read_bytes()
        self.run_shell(r'''
prepare_reinstall
[[ $REUSE_CONFIG == 1 && $REUSE_UNIT == 1 ]]
[[ $OLD_PORT == 32568 && $OLD_PSK == test-only-key ]]
[[ -z $NODE_EXTRA ]]
''')
        self.assertEqual(self.config.read_bytes(), original)

    def test_http_obfuscation_and_crlf(self):
        self.config.write_bytes(b"[snell-server]\r\nlisten = [::]:443\r\npsk = test-key==\r\nobfs = http\r\n")
        out = self.run_shell(r'''
prepare_reinstall
[[ $OLD_PORT == 443 && $OLD_PSK == test-key== ]]
show_result 203.0.113.10 "$OLD_PORT" "$OLD_PSK"
''').stdout
        self.assertIn("我的VPS = snell, 203.0.113.10, 443, psk=test-key==, version=5, obfs=http\n", out)
        self.assertNotIn("\x1b", out)

    def test_backup_replace_and_failed_start_restores_old_install(self):
        old = {p: p.read_bytes() for p in (self.binary, self.config, self.unit, self.proxy)}
        extra = self.conf / "unrelated.txt"
        extra.write_text("keep")
        self.run_shell(r'''
REINSTALL=1
prepare_reinstall
backup_install
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
printf 'new-node\n' > "$TEST_ROOT/new-node"
create_file "$TEST_ROOT/new-node" "$CONF_DIR/surge-proxy.txt" 600
systemctl start snell.service
''', expect=1)
        for path, content in old.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(extra.read_text(), "keep")
        self.assertFalse((self.root / "userdel.log").exists())
        self.assertEqual(len(list((self.root / "backups").glob("backup-*"))), 1)
        self.assertGreaterEqual((self.root / "systemctl.log").read_text().count("start snell.service"), 2)

    def test_successful_replace_retains_backup(self):
        self.source.write_text("new-valid-binary\n")
        self.run_shell(r'''
REINSTALL=1
prepare_reinstall
backup_install
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
systemctl start snell.service
DONE=1
''')
        self.assertEqual(self.binary.read_text(), "new-valid-binary\n")
        backups = list((self.root / "backups").glob("backup-*/snell-server"))
        self.assertEqual(backups[0].read_text(), "old-valid-binary\n")
        self.assertEqual(self.proxy.read_text(), "old-node\n")

    def test_failed_reinstall_does_not_start_previously_stopped_service(self):
        self.run_shell(r'''
REINSTALL=1
backup_install
OLD_ACTIVE=0
OLD_ENABLED=disabled
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
exit 1
''', expect=1)
        log = (self.root / "systemctl.log").read_text()
        self.assertNotIn("start snell.service", log)
        self.assertNotIn("disable snell.service", log)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_backup_and_restore_permissions(self):
        self.binary.chmod(0o750)
        self.run_shell(r'''
REINSTALL=1
backup_install
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
exit 1
''', expect=1)
        self.assertEqual(self.binary.stat().st_mode & 0o777, 0o750)
        backup = next((self.root / "backups").glob("backup-*"))
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)

    def test_unbacked_file_cannot_be_overwritten(self):
        self.run_shell('create_file "$TEST_ROOT/new-binary" "$BIN" 755\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_changed_after_backup_cannot_be_overwritten(self):
        self.run_shell(r'''
REINSTALL=1
backup_install
printf 'external change\n' > "$BIN"
create_file "$TEST_ROOT/new-binary" "$BIN" 755
''', expect=1)
        self.assertEqual(self.binary.read_text(), "external change\n")

    def test_new_install_failure_removes_only_new_resources(self):
        self.binary.unlink()
        self.unit.unlink()
        self.proxy.unlink()
        self.run_shell(r'''
CREATED=1
USER_CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
exit 1
''', expect=1)
        self.assertFalse(self.binary.exists())
        self.assertTrue(self.config.exists())
        self.assertEqual((self.root / "userdel.log").read_text(), "snell-auto\n")

    def test_no_file_changes_failure_keeps_old_service(self):
        self.run_shell(r'''
REINSTALL=1
backup_install
CREATED=1
exit 1
''', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")
        self.assertIn("start snell.service", (self.root / "systemctl.log").read_text())

    def test_symlink_is_not_overwritten(self):
        self.binary.unlink()
        self.binary.symlink_to(self.source)
        self.run_shell('prepare_reinstall\n', expect=1)
        self.assertTrue(self.binary.is_symlink())

    def test_similar_binary_path_is_not_accepted(self):
        self.run_shell('MOCK_BINARY_PATH="$BIN-old"\nprepare_reinstall\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_similar_config_path_is_not_accepted(self):
        self.run_shell('MOCK_CONFIG_PATH="$CONF_DIR/snell-server.conf.other"\nprepare_reinstall\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_missing_unit_is_rejected_before_transaction(self):
        self.run_shell('MOCK_LOAD_STATE=not-found\nprepare_reinstall\n', expect=1)
        log = (self.root / "systemctl.log").read_text()
        self.assertNotIn("stop snell.service", log)
        self.assertNotIn("disable snell.service", log)

    def test_rollback_preserves_file_created_by_other_process(self):
        out = self.run_shell(r'''
REINSTALL=1
backup_install
CREATED=1
rm() {
    command rm "$@"
    if [[ $* == "-- $BIN" ]]; then
        printf 'other-process-file\n' > "$BIN"
    fi
}
create_file "$TEST_ROOT/new-binary" "$BIN" 755
''', expect=1)
        self.assertEqual(self.binary.read_text(), "other-process-file\n")
        self.assertIn("文件被其他程序替换，未删除", out.stderr)
        backup = next((self.root / "backups").glob("backup-*/snell-server"))
        self.assertEqual(backup.read_text(), "old-valid-binary\n")

    def test_custom_listener_is_rejected_without_changes(self):
        self.config.write_text("[snell-server]\nlisten = 127.0.0.1:1234\npsk = example\n")
        self.run_shell('prepare_reinstall\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")


if __name__ == "__main__":
    unittest.main()
