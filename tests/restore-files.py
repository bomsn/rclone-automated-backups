"""Exercise actual archive writes, privilege boundaries and destructive guards."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / "lib" / "restore-files.py"


class RestoreFiles(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="rclone-files-boundary-")
        self.base = Path(self.work.name)
        self.target = self.base / "target"
        self.target.mkdir()
        self.identity = self.run_helper("identity").stdout.strip()

    def tearDown(self):
        self.work.cleanup()

    def run_helper(self, action, *extra, data=None):
        args = ["python3", str(HELPER), action, str(self.target)]
        if action != "identity":
            args += ["--identity", self.identity]
        return subprocess.run(args + list(extra), input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def archive(self, entries):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            for name, data in entries:
                entry = tarfile.TarInfo(name)
                if isinstance(data, tuple):
                    entry.type, entry.linkname = data
                    archive.addfile(entry)
                else:
                    entry.size = len(data)
                    entry.mode = 0o6755
                    archive.addfile(entry, io.BytesIO(data))
        return output.getvalue()

    def test_regular_hidden_files_clear_and_preserved_config(self):
        (self.target / ".old-hidden").write_text("old")
        (self.target / "wp-config.php").write_text("target credentials")
        data = self.archive([("nested/file", b"restored"), (".hidden", b"hidden"), ("wp-config.php", b"SOURCE")])
        result = self.run_helper("archive", "--clear", "--preserve", "wp-config.php", data=data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / "nested/file").read_bytes(), b"restored")
        self.assertEqual((self.target / "wp-config.php").read_text(), "target credentials")
        self.assertFalse((self.target / ".old-hidden").exists())
        self.assertEqual((self.target / "nested/file").stat().st_mode & 0o7000, 0)

    def test_archive_modification_time_is_retained(self):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w') as archive:
            entry = tarfile.TarInfo('asset.css')
            entry.size, entry.mode, entry.mtime = 4, 0o644, 1700000000
            archive.addfile(entry, io.BytesIO(b'body'))
        result = self.run_helper('archive', data=output.getvalue())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / 'asset.css').stat().st_mtime, 1700000000)

    def test_bad_archives_do_not_clear_existing_files(self):
        marker = self.target / "keep"
        marker.write_text("safe")
        cases = [[("../outside", b"bad")], [("/absolute", b"bad")], [("link", (tarfile.SYMTYPE, "../../outside"))], [("device", (tarfile.FIFOTYPE, ""))]]
        for entries in cases:
            with self.subTest(entries=entries):
                result = self.run_helper("archive", "--clear", data=self.archive(entries))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(marker.read_text(), "safe")

    def test_existing_directory_symlink_cannot_redirect_write(self):
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "file").write_text("safe")
        (self.target / "redirect").symlink_to(outside, target_is_directory=True)
        result = self.run_helper("archive", data=self.archive([("redirect/file", b"bad")]))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((outside / "file").read_text(), "safe")

    def test_links_are_delayed_and_safe_internal_links_survive(self):
        result = self.run_helper("archive", data=self.archive([("link", (tarfile.SYMTYPE, "nested/file")), ("nested/file", b"content"), ("hard", (tarfile.LNKTYPE, "nested/file"))]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / "link").read_bytes(), b"content")
        self.assertEqual((self.target / "hard").stat().st_ino, (self.target / "nested/file").stat().st_ino)

    def test_destination_replacement_requires_new_review(self):
        self.target.rename(self.base / "old")
        self.target.mkdir()
        result = self.run_helper("archive", data=self.archive([("file", b"bad")]))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.target / "file").exists())

    def test_site_owner_is_used_and_archive_owner_is_ignored(self):
        if os.geteuid() != 0:
            self.skipTest("Privilege boundary requires the isolated root lab")
        os.chown(self.target, 65534, 65534)
        self.identity = self.run_helper("identity").stdout.strip()
        result = self.run_helper("archive", data=self.archive([("file", b"unprivileged")]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / "file").stat().st_uid, 65534)

    def test_private_sql_is_not_restored_into_webroot(self):
        archive = self.base / "source.tar.gz"
        key = "a" * 32
        archive.write_bytes(self.archive([(f"{key}_database_test.sql", b"SELECT 1;"), ("index.php", b"site")]))
        sql = self.base / "private.sql"
        environment = os.environ | {"RESTORE_SQL": str(sql)}
        command = ["bash", "-c", 'exec "$@" 3> "$RESTORE_SQL"', "bash", "python3", str(HELPER), "archive", str(self.target), "--identity", self.identity.decode(), "--database-hash", key]
        with archive.open("rb") as incoming:
            result = subprocess.run(command, stdin=incoming, env=environment, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sql.read_bytes(), b"SELECT 1;")
        self.assertFalse(list(self.target.glob("*.sql")))


if __name__ == "__main__":
    unittest.main()
