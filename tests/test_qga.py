"""Regression tests for the shared VM guest-agent helper (no VM needed)."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "qga.py"
spec = importlib.util.spec_from_file_location("gnosislab_qga", MODULE)
qga = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qga)


class TestQga(unittest.TestCase):
    def test_ping_actually_contacts_agent(self):
        with patch.object(qga.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, '{"return":{}}', "")) as run:
            self.assertEqual(qga.main(["test-domain", "ping"]), 0)
            self.assertEqual(json.loads(run.call_args.args[0][-3])["execute"], "guest-ping")

    def test_failed_ping_cannot_claim_ready(self):
        with patch.object(qga.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, "", "agent unavailable")):
            with self.assertRaises(qga.QGAError):
                qga.request("vm", {"execute": "guest-ping"}, retries=1)

    def test_qga_error_contains_virsh_stderr(self):
        with patch.object(qga.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, "", "Guest agent is not responding")):
            with self.assertRaisesRegex(qga.QGAError, "not responding"):
                qga.request("vm", {"execute": "guest-ping"}, retries=1)

    def test_resumable_execution_has_stable_identity(self):
        requests = []
        def fake_request(domain, payload, retries=5):
            requests.append(payload)
            if payload["execute"] == "guest-exec":
                return {"pid": 100}
            if payload["execute"] == "guest-file-open":
                path = payload["arguments"]["path"]
                if path.endswith(".rc"):
                    return 3
                raise qga.QGAError("No such file")
            if payload["execute"] == "guest-file-read":
                return {"buf-b64": "MAo="}
            return {}
        with patch.object(qga, "request", side_effect=fake_request):
            self.assertEqual(qga.run("vm", "true", key="base-packages"), 0)
            self.assertEqual(qga.run("vm", "true", key="base-packages"), 0)
        shells = [p["arguments"]["arg"] for p in requests if p["execute"] == "guest-exec"]
        self.assertEqual(shells[0], shells[1])


if __name__ == "__main__":
    unittest.main()
