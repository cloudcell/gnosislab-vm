"""Verify experiment Quadlet recovers when its configuration did not change."""
from pathlib import Path
import unittest

UPGRADE = (Path(__file__).resolve().parents[1] / "30-ensure-lab-tools.sh").read_text()

class ExpServiceRecoveryTests(unittest.TestCase):
    def test_inactive_service_is_restarted_after_unchanged_quadlet(self):
        anchor = 'note "experiment service inactive — clearing failure limit and starting"'
        self.assertIn(anchor, UPGRADE)
        self.assertIn('systemctl --user reset-failed lab-cnt-exp', UPGRADE)
        self.assertIn('systemctl --user start lab-cnt-exp', UPGRADE)
        self.assertIn('FAIL: experiment container remains inactive', UPGRADE)
        self.assertLess(UPGRADE.index('quadlet already current'), UPGRADE.index(anchor))
        self.assertLess(UPGRADE.index(anchor), UPGRADE.index('note "restarting trusted container'))

if __name__ == "__main__":
    unittest.main()
