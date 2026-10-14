"""Fail-closed tests for Feature 7A trusted MCP runtime asset paths.

Static tests guard the trust boundary; live VM checks remain required.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
QUADLET = ROOT / "deploy/quadlets/lab-cnt-mcp.container"
BUILD = ROOT / "create-lab-template"
UPGRADE = ROOT / "30-ensure-lab-tools.sh"
SECURITY = ROOT / "deploy/security-battery.sh"


class TrustedRuntimeAssetTests(unittest.TestCase):
    def test_trusted_quadlet_never_uses_agent_writable_security_assets(self):
        content = QUADLET.read_text()
        self.assertIn("SeccompProfile=/etc/labloop/seccomp-labloop.json", content)
        self.assertIn("@MCP_ENTRYPOINT_VOLUME@", content)
        self.assertNotRegex(
            content, r"(?m)^(?:SeccompProfile|Volume)="
            r"/srv/lab/workspace/.*(?:entrypoint|seccomp)",
        )

    def test_initial_build_installs_root_only_assets_before_start(self):
        content = BUILD.read_text()
        self.assertIn(
            'install -m 0644 -o root -g root /etc/labloop/.seccomp-next',
            content,
        )
        self.assertIn(
            'install -m 0755 -o root -g root /usr/local/libexec/.labloop-mcp-next',
            content,
        )
        self.assertLess(
            content.index("note \"installing root-owned trusted MCP runtime assets\""),
            content.index('systemctl --user daemon-reload && systemctl --user start lab-cnt-mcp'),
        )
        self.assertIn(
            "'Volume=/usr/local/libexec/labloop-mcp-entrypoint:"
            "/usr/local/bin/labloop-mcp:ro'",
            content,
        )
        self.assertIn("@MCP_ENTRYPOINT_VOLUME@", content)

    def test_upgrade_stages_outside_tmp_and_blocks_legacy_untrusted_code(self):
        content = UPGRADE.read_text()
        self.assertIn("if [ \"$img_pkg\" != 1 ]; then", content)
        self.assertIn('qga_push "$vm" "$REPO/containers/mcp/entrypoint.sh" '
                      '/usr/local/libexec/.labloop-mcp-next', content)
        self.assertIn('qga_push "$vm" "$REPO/deploy/seccomp-labloop.json" '
                      '/etc/labloop/.seccomp-next', content)
        self.assertNotIn("ensure-entrypoint.sh", content)
        self.assertNotIn("ensure-seccomp.json", content)
        self.assertIn("refusing to promote agent-writable executable", content)
        self.assertIn("refusing an insecure partial upgrade", content)
        self.assertIn("defer", content)
        self.assertIn("@MCP_ENTRYPOINT_VOLUME@", content)
        self.assertIn("systemctl --user daemon-reload && systemctl --user restart lab-cnt-mcp", content)

    def test_security_battery_checks_trusted_asset_ownership(self):
        content = SECURITY.read_text()
        self.assertIn("trusted-entrypoint-root-owned", content)
        self.assertIn("trusted-seccomp-root-owned", content)
        self.assertIn("trusted-quadlet-mount", content)

    def test_rendered_runtime_paths_are_not_workspace_backed(self):
        content = QUADLET.read_text()
        ports = ["PublishPort=127.0.0.1:28080:28080"]
        mount = "Volume=/usr/local/libexec/labloop-mcp-entrypoint:/usr/local/bin/labloop-mcp:ro"
        rendered = content.replace("@MCP_PORTS_PUBLISH@", "\n".join(ports)).replace(
            "@MCP_ENTRYPOINT_VOLUME@", mount
        )
        self.assertNotRegex(rendered, r"@MCP_[A-Z_]+@")
        self.assertEqual(rendered.count("Volume=/usr/local/libexec/labloop-mcp-entrypoint:"), 1)
        self.assertNotIn("SeccompProfile=/srv/lab/workspace", rendered)


if __name__ == "__main__":
    unittest.main()
