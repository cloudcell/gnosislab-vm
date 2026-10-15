"""Template provisioning must grant only necessary zone traversal."""
from pathlib import Path
import unittest

BUILD = (Path(__file__).resolve().parents[1] / "create-lab-template").read_text()

class TemplateACLTests(unittest.TestCase):
    def test_parent_has_search_only_acls(self):
        self.assertIn("setfacl -m u:lab:--x,u:exp:--x,u:mcp:--x /srv/lab", BUILD)
        self.assertNotIn("chmod 755 /srv/lab", BUILD)

    def test_zone_access_and_state_separation(self):
        self.assertIn("chmod 700 /srv/lab/mcp-state", BUILD)
        self.assertIn("setfacl -m u:exp:r-x,u:mcp:r-x /srv/lab/workspace", BUILD)
        self.assertIn("setfacl -m u:exp:r-x,u:mcp:r-x /srv/lab/incoming", BUILD)
        self.assertIn("setfacl -m u:lab:rwx,u:mcp:r-x /srv/lab/exchange", BUILD)
        self.assertIn("test ! -r /srv/lab/mcp-state", BUILD)

    def test_acl_preflight_precedes_container_build(self):
        self.assertLess(BUILD.index('note "/srv/lab layout + ACLs"'),
                        BUILD.index('note "staging whitelisted payloads on the host"'))

if __name__ == "__main__":
    unittest.main()
