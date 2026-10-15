"""Regression guards for recovery of missing exp image and MCP startup."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
UPGRADE = (ROOT / "30-ensure-lab-tools.sh").read_text()
MCP = (ROOT / "deploy/quadlets/lab-cnt-mcp.container").read_text()


class ContainerRecovery(unittest.TestCase):
    def test_exp_image_is_checked_before_service_restart(self):
        self.assertIn("--rebuild-exp-image", UPGRADE)
        self.assertIn("podman image exists lab-img-exp", UPGRADE)
        self.assertLess(UPGRADE.index("podman image exists lab-img-exp"),
                        UPGRADE.index('note "ensuring exp/mcp Quadlet directories"'))

    def test_exp_upload_integrity_and_durable_guest_driver(self):
        self.assertIn('QGA_DRIVER="$REPO/scripts/qga.py"', UPGRADE)
        self.assertNotIn('cat > "$WORK/qga.py"', UPGRADE)
        self.assertIn('sha256sum -c -', UPGRADE)
        self.assertIn("context.part", UPGRADE)
        self.assertIn("context.tar", UPGRADE)
        self.assertLess(UPGRADE.index("sha256sum -c -"),
                        UPGRADE.index("tar -xf '$stage/context.tar'"))

    def test_mcp_token_is_preserved_and_restricted(self):
        self.assertIn('if test -e "$file"; then', UPGRADE)
        self.assertIn('chmod 0600 "$file"', UPGRADE)
        self.assertIn('su - mcp -c "test -r /srv/lab/mcp-state/ingest.env"', UPGRADE)
        self.assertLess(UPGRADE.index('note "verifying mcp ingest token ownership"'),
                        UPGRADE.index('note "restarting trusted container on protected runtime configuration"'))

    def test_health_port_expansion_is_deferred_to_container(self):
        self.assertIn("$$" + "{ML_EPISTEME_PORT}", MCP)
        self.assertNotIn("127.0.0.1:" + "${ML_EPISTEME_PORT}/health", MCP)


if __name__ == "__main__":
    unittest.main()
