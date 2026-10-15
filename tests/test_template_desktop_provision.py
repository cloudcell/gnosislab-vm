"""Template must provision VSIX files readably and Desktop before use."""
from pathlib import Path
import unittest

BUILD=(Path(__file__).resolve().parents[1]/"create-lab-template").read_text()
class DesktopProvisioningTests(unittest.TestCase):
    def test_vscode_extension_archive_private_to_lab(self):
        self.assertIn("chown lab:lab '/tmp/$v' && chmod 0600 '/tmp/$v'",BUILD)
        self.assertIn('|| die "failed to install/verify VSIX $v"', BUILD)
        self.assertIn('codium --list-extensions',BUILD)

    def test_desktop_created_before_writing_configure_host_models(self):
        self.assertLess(
            BUILD.index("install -d -m 0755 -o lab -g lab /home/lab/Desktop /home/lab/.config/opencode"),
            BUILD.index("/home/lab/Desktop/configure-host-models.py &&"))
        self.assertIn("test ! -L /home/lab/Desktop",BUILD)

if __name__=="__main__":
    unittest.main()
