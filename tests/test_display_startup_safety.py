"""Custom XRandR hooks must never be forced during graphical startup."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
BUILD=(ROOT/"create-lab-template").read_text()
ENSURE=(ROOT/"30-ensure-lab-tools.sh").read_text()
class DisplaySafetyTests(unittest.TestCase):
    def test_builder_removes_lightdm_and_xdg_hooks(self):
        self.assertIn("rm -f /tmp/labloop-display.conf", BUILD)
        self.assertIn("/etc/lightdm/lightdm.conf.d/50-labloop-display.conf", BUILD)
        self.assertNotIn('qga_push "$REPO/deploy/labloop-display.sh"', BUILD)
        self.assertNotIn('qga_push "$REPO/deploy/labloop-display-lightdm.conf"', BUILD)
    def test_ensure_removes_hooks_and_does_not_push_them(self):
        self.assertIn("rm -f /etc/lightdm/lightdm.conf.d/50-labloop-display.conf", ENSURE)
        self.assertIn("test ! -e /etc/lightdm/lightdm.conf.d/50-labloop-display.conf", ENSURE)
        self.assertNotIn('labloop-display.sh labloop-display.desktop', ENSURE)
        self.assertNotIn('/tmp/ensure-labloop-display-lightdm.conf', ENSURE)
if __name__=="__main__":
    unittest.main()
