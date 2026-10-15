"""Readiness export must not destroy a deliberately staged user artifact."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
EXPORT=(ROOT/"deploy/labloop-export").read_text()
BATTERY=(ROOT/"deploy/functional-battery.sh").read_text()
MANUAL=(ROOT/"deploy/DATA-MOVEMENT-MANUAL.md").read_text()

class ExportIsolationTests(unittest.TestCase):
    def test_private_staging_with_cleanup(self):
        self.assertIn('SELFTEST=0',EXPORT)
        self.assertIn('"--self-test"',EXPORT)
        self.assertIn('STAGE=$(mktemp -d "$stage_parent/.selftest.XXXXXXXX")',EXPORT)
        self.assertIn("trap 'rm -rf -- \"$STAGE\"' EXIT",EXPORT)
        self.assertIn('isolated export self-test passed',EXPORT)
    def test_battery_never_overwrites_real_user_export(self):
        self.assertIn('labloop-export --self-test "$probe"',BATTERY)
        self.assertNotIn('labloop-export /srv/lab/exchange/.exp-probe',BATTERY)
        self.assertNotIn('/var/lib/labloop-export/user/manifest.json',BATTERY)
    def test_snapshot_mode_is_explicit(self):
        self.assertIn('90-extract-lab-data.sh --all lab-vm-rc-26',MANUAL)
        self.assertIn('The default is **not** a newest-first selection',MANUAL)
if __name__=="__main__":
    unittest.main()
