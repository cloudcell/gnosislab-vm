"""Check readiness recognizes OpenCode's displayed version and detects stale launchers."""
from pathlib import Path
import re
import unittest
READY=(Path(__file__).resolve().parents[1]/"deploy/check-lab-ready.sh").read_text()
PATTERN=r'^(opencode[\s]+)?v?2\.[0-9]+\.[0-9]+([-.+][\w.-]+)?$'
class VersionTests(unittest.TestCase):
    def test_reported_version_formats(self):
        for output in ("opencode v2.0.29","2.0.29","v2.0.29","opencode 2.0.29"):
            self.assertRegex(output,PATTERN)
        for output in ("1.0.29","opencode v1.0.29","error",""):
            self.assertNotRegex(output,PATTERN)
    def test_launcher_parity_is_enforced(self):
        self.assertIn('launcher_version=$(/usr/local/bin/opencode --version',READY)
        self.assertIn('"$version" != "$launcher_version"',READY)
        self.assertIn('lab-owned OpenCode $version; launcher matches',READY)
if __name__=="__main__":
    unittest.main()
