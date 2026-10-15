"""Regression coverage for truthful warnings and repeatable installation."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
SEC=(ROOT/"deploy/security-battery.sh").read_text()
READY=(ROOT/"deploy/check-lab-ready.sh").read_text()
BUILD=(ROOT/"create-lab-template").read_text()
CACHE=(ROOT/"selfbuild/prefetch-cache.sh").read_text()
class WarningsTests(unittest.TestCase):
    def test_private_quadlet_is_expected_and_readable_is_failure(self):
        self.assertIn('bad trusted-quadlet-private "lab can read',SEC)
        self.assertIn('ok trusted-quadlet-private "MCP service active',SEC)
        self.assertNotIn('note trusted-quadlet-mount "mcp quadlet unreadable',SEC)
    def test_headless_display_skipped_and_hook_detected(self):
        self.assertIn("SKIP  %-34s",READY)
        self.assertIn('bad display-hook "obsolete forced XRandR hook',READY)
        self.assertNotIn('warn display-mode "no X session',READY)
    def test_cached_apt_does_not_update_public_mirrors(self):
        line=next(x for x in BUILD.splitlines() if 'exec --resume base-packages' in x)
        self.assertNotIn('apt-get update -qq || true',line)
        self.assertIn('APT_PRELUDE',line)
    def test_uv_selects_one_newest_cached_wheel(self):
        self.assertIn("sort -V | tail -1",BUILD)
        self.assertIn('pipx install --force',BUILD)
        self.assertNotIn('pipx install /tmp/uvx-wheels/uv-*.whl',BUILD)
    def test_aged_artifacts_not_described_as_offline(self):
        self.assertIn('NOTE: $l verified, but cache age exceeds freshness target',CACHE)
if __name__=="__main__":
    unittest.main()
