"""Cached image loading must work with rootless Podman without opening /tmp."""
from pathlib import Path
import unittest

BUILD=(Path(__file__).resolve().parents[1]/"create-lab-template").read_text()

class CacheImportTests(unittest.TestCase):
    def test_guest_cache_probe_precedes_package_stage(self):
        self.assertLess(BUILD.index('note "checking guest reachability of artifact cache"'),BUILD.index('note "base packages"'))
        self.assertIn('guest_cache_ok',BUILD)

    def test_archives_are_accessible_only_to_owner(self):
        self.assertIn('import_dir=/var/cache/gnosislab/image-import',BUILD)
        self.assertIn('chown mcp:mcp',BUILD)
        self.assertIn('chown exp:exp',BUILD)
        self.assertIn('chmod 0600',BUILD)
        self.assertIn('sha256sum -c -',BUILD)
        self.assertIn("trap 'rm -f",BUILD)
        self.assertNotIn("podman load -i /tmp/",BUILD)

if __name__=="__main__":
    unittest.main()
