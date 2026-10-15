"""QGA shell snippets must not evaluate guest checks on the host."""
from pathlib import Path
import unittest
SOURCE=(Path(__file__).resolve().parents[1]/"30-ensure-lab-tools.sh").read_text()
class OpenCodeQGATests(unittest.TestCase):
    def test_guest_metadata_checks_are_escaped(self):
        for prefix in ("stat -c %U /home/lab/.opencode/bin/opencode", "head -c 4 /home/lab/.opencode/bin/opencode", "head -c 4 /usr/local/bin/opencode"):
            self.assertIn("\\$(" + prefix, SOURCE)
            self.assertNotIn('test "$(' + prefix, SOURCE)
    def test_failure_not_suppressed(self):
        self.assertIn("FAIL: workspace/OpenCode provisioning failed", SOURCE)
        self.assertNotIn('warn: workspace refresh failed (workspace absent?)', SOURCE)
if __name__=="__main__":
    unittest.main()
