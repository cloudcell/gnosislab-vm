"""The host model configurator belongs only in optional-patches."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
BUILD=(ROOT/"create-lab-template").read_text()
ENSURE=(ROOT/"30-ensure-lab-tools.sh").read_text()
DESKTOP=(ROOT/"scripts/ensure-vm-desktop.sh").read_text()

class DesktopConfiguratorLocationTests(unittest.TestCase):
    def test_fresh_template_uses_optional_patches(self):
        self.assertIn("/home/lab/Desktop/optional-patches/configure-host-models.py",BUILD)
        self.assertNotIn("/home/lab/Desktop/configure-host-models.py",BUILD)
    def test_existing_vm_uses_optional_patches(self):
        self.assertIn("/home/lab/Desktop/optional-patches/configure-host-models.py",ENSURE)
        self.assertNotIn("/home/lab/Desktop/configure-host-models.py",ENSURE)
    def test_remove_only_identical_legacy_copy(self):
        self.assertIn('cmp -s "$duplicate" "$canonical"',DESKTOP)
        self.assertIn('elif [ -f "$duplicate" ]',DESKTOP)
        self.assertIn('if [ -L "$duplicate" ]',DESKTOP)
        self.assertIn('rm -f -- "$duplicate"',DESKTOP)
        self.assertIn('differs from canonical optional-patches copy; preserved',DESKTOP)

if __name__=="__main__":
    unittest.main()
