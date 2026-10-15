"""Driver must never hold passwordless root full-export permission."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
SUDO=(R/"deploy/labloop.sudoers").read_text()
BAT=(R/"deploy/security-battery.sh").read_text()
FUN=(R/"deploy/functional-battery.sh").read_text()
READY=(R/"deploy/check-lab-ready.sh").read_text()
class LeastPrivilege(unittest.TestCase):
 def test_no_root_export_grant(self):
  self.assertNotIn("lab ALL=(root) NOPASSWD: /usr/local/sbin/labloop-export --all",SUDO)
  self.assertIn("export-operator-only",BAT)
 def test_path_mode_still_tested(self):
  self.assertIn("labloop-export --self-test",FUN)
  self.assertIn("host-QGA owns full export",FUN)
 def test_gui_wrapper_does_not_require_terminal_binary(self):
  self.assertIn("command -v x-terminal-emulator",READY)
if __name__=="__main__":
 unittest.main()
