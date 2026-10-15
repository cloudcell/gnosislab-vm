"""Ensure self-updated OpenCode is the same binary reached by the system launcher."""
from pathlib import Path
import unittest
S=(Path(__file__).resolve().parents[1]/"30-ensure-lab-tools.sh").read_text()
class OpenCodeLauncherTests(unittest.TestCase):
    def test_launcher_is_staged_and_replaced_atomically(self):
        self.assertIn("opencode-launcher opencode-update-command.md",S)
        self.assertIn('install -m 0755 -o root -g root /tmp/ensure-opencode-launcher "$n"',S)
        self.assertIn('mv -f -T "$n" "$t"',S)
    def test_versions_compared_before_workspace(self):
        self.assertIn('test "$direct" = "$actual"',S)
        self.assertLess(S.index('OpenCode direct/launcher'),S.index('note "refreshing workspace'))
    def test_cannot_succeed_after_failure(self):
        self.assertIn('FAIL: OpenCode launcher repair',S)
        self.assertIn('FAIL: workspace/OpenCode provisioning failed',S)
if __name__=="__main__":
 unittest.main()
