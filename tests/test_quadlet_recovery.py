"""Regression checks for clone recovery when rootless Quadlet dirs are absent."""
from pathlib import Path
import unittest

SCRIPT = (Path(__file__).resolve().parents[1] / "30-ensure-lab-tools.sh").read_text()

class QuadletRecoveryTests(unittest.TestCase):
    def test_directory_preflight_before_quadlet_install(self):
        self.assertIn('note "ensuring exp/mcp Quadlet directories"', SCRIPT)
        self.assertLess(SCRIPT.index('note "ensuring exp/mcp Quadlet directories"'),
                        SCRIPT.index('note "mcp quadlet changed'))
        self.assertIn('"$home/.config/containers/systemd"', SCRIPT)
        self.assertIn('install -d -m 0755 -o "$account" -g "$account"', SCRIPT)
        self.assertIn('refusing symlinked Quadlet path', SCRIPT)

    def test_missing_experiment_quadlet_is_not_reported_as_success(self):
        self.assertIn('exp_quadlet_failed=0', SCRIPT)
        self.assertIn('exp_quadlet_failed=1', SCRIPT)
        self.assertIn('if [ "$exp_quadlet_failed" = 1 ]; then', SCRIPT)
        self.assertNotIn('warn: quadlet install/restart failed', SCRIPT)

if __name__ == "__main__":
    unittest.main()
