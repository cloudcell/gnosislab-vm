"""Detect and fail closed on unsupported OpenCode updater layout."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
ENSURE=(ROOT/"30-ensure-lab-tools.sh").read_text()
READY=(ROOT/"deploy/check-lab-ready.sh").read_text()
class InstallMethodTests(unittest.TestCase):
 def test_migrate_only_elf_not_shell_launcher(self):
  self.assertIn('7f454c46',ENSURE)
  self.assertIn('test ! -L /usr/local/bin/opencode',ENSURE)
  self.assertIn('test ! -L /home/lab/.opencode/bin/opencode',ENSURE)
  self.assertIn('/home/lab/.opencode/bin/opencode --version',ENSURE)
 def test_readiness_checks_updater_path(self):
  self.assertIn('USERBIN=/home/lab/.opencode/bin/opencode',READY)
  self.assertIn('bad opencode-updater',READY)
  self.assertIn('ok opencode-updater',READY)
  self.assertNotIn('npm pin is',READY)
if __name__=="__main__":
 unittest.main()
