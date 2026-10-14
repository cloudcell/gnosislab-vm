"""VM trial isolation must be required by the trusted MCP supervisor.

The runtime dependency is the GnosisLab release containing the
ML_EPISTEME_TRIAL_ISOLATION=enforced executor implementation.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENTRY = ROOT / "containers/mcp/entrypoint.sh"
BUILDER = ROOT / "create-lab-template"


class VmTrialIsolationTests(unittest.TestCase):
    def test_supervisor_requires_full_isolation_before_starting_services(self):
        text = ENTRY.read_text()
        self.assertIn("export ML_EPISTEME_TRIAL_ISOLATION=enforced", text)
        self.assertIn("export ML_EPISTEME_SANDBOX=full", text)
        self.assertIn('LocalExecutor(sandbox="full", trace_reads="off")', text)
        self.assertIn('"--unshare-net"', text)
        self.assertIn('"--unshare-pid"', text)
        self.assertIn('["--tmpfs", "/state"]', text)
        self.assertLess(text.index("python3 - <<'PY'"), text.index("start arete"))
        self.assertLess(text.index("start arete"), text.index("start episteme"))

    def test_no_unprotected_opt_out(self):
        text = ENTRY.read_text()
        self.assertNotIn("ML_EPISTEME_TRIAL_ISOLATION=off", text)
        self.assertNotIn("ML_EPISTEME_SANDBOX=none", text)
        self.assertIn("FATAL: GnosisLab VM trial isolation unavailable", text)

    def test_vm_pinned_release_requires_follow_up(self):
        text = BUILDER.read_text()
        # This PR must not silently bump pinned Python package dependencies.
        self.assertIn('GNOSISLAB_VER="${GNOSISLAB_VER:-0.1.42}"', text)


if __name__ == "__main__":
    unittest.main()
