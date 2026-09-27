import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import main as app


class CheckoutCleanupTests(unittest.TestCase):
    def test_readonly_git_pack_removed_without_touching_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / 'project'
            checkout.mkdir()
            marker = checkout / 'keep.txt'
            marker.write_text('replacement')
            archived = root / 'project.old-test'
            pack = archived / '.git' / 'objects' / 'pack' / 'pack.idx'
            pack.parent.mkdir(parents=True)
            pack.write_text('old index')
            pack.chmod(stat.S_IREAD)
            with patch.object(app, 'BASE_DIR', root), patch.object(app, 'log'):
                app.finalize_refreshed_checkout(checkout, archived, False)
            self.assertFalse(archived.exists())
            self.assertEqual(marker.read_text(), 'replacement')

    def test_kept_backup_and_unexpected_path_are_not_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / 'project'
            checkout.mkdir()
            other = root / 'valuable'
            other.mkdir()
            with patch.object(app, 'BASE_DIR', root):
                app.finalize_refreshed_checkout(checkout, other, True)
                with self.assertRaises(app.RepoWayfinderError):
                    app.finalize_refreshed_checkout(checkout, other, False)
            self.assertTrue(other.is_dir())

    def test_locked_file_failure_is_reported_not_claimed_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / 'project'; checkout.mkdir()
            archived = root / 'project.old-test'; archived.mkdir()
            with patch.object(app, 'BASE_DIR', root), patch.object(app.shutil, 'rmtree', side_effect=PermissionError('locked')), patch.object(app, 'log') as log:
                app.finalize_refreshed_checkout(checkout, archived, False)
            self.assertTrue(archived.exists())
            self.assertIn('暂时无法删除', log.call_args.args[0])

if __name__ == '__main__':
    unittest.main()
