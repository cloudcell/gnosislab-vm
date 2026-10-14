"""Offline unit checks for the external-VM publication verifier."""
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "vm_publication_attestation", HERE / "scripts/vm_publication_attestation.py"
)
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.name = "lab-template-20261014T1230Z.qcow2"
        self.image = Path(self.temp.name) / self.name
        self.image.write_bytes(b"test artifact")
        self.digest = hashlib.sha256(b"test artifact").hexdigest()
        self.checksum = Path(self.temp.name) / (self.name + ".sha256")
        self.checksum.write_text(f"{self.digest}  {self.name}\n", encoding="ascii")

    def record(self):
        return {"verificationResult": {"statement": {
            "predicateType": app.PREDICATE,
            "predicate": {
                "schemaVersion": 1,
                "assertion": "local-vm-publication",
                "imageName": self.name,
                "publisherCheckoutCommit": "a" * 40,
                "buildLocation": "external-kvm-host",
                "githubBuildPerformed": False,
            },
            "subject": [
                {"name": self.name, "digest": {"sha256": self.digest}},
                {"name": self.name + ".sha256", "digest": {"sha256": app.sha256(self.checksum)}},
            ]
        }}}

    def test_checksum_validated(self):
        self.assertEqual(app.checksum_info(self.checksum), (self.name, self.digest))
        with self.assertRaises(app.PublicationError):
            app.checksum_info(self.checksum, "other.qcow2")
        self.checksum.write_text(f"{self.digest}  ../escape.qcow2\n")
        with self.assertRaises(app.PublicationError):
            app.checksum_info(self.checksum)

    def test_image_and_sidecar_must_both_be_signed(self):
        assert app.matching_statement(
            [self.record()], self.name, self.digest, app.sha256(self.checksum), "a" * 40
        )
        assert not app.matching_statement(
            [self.record()], self.name, "b" * 64, app.sha256(self.checksum)
        )
        assert not app.matching_statement(
            [self.record()], self.name, self.digest, "c" * 64
        )
        assert not app.matching_statement(
            [self.record()], self.name, self.digest, app.sha256(self.checksum), "d" * 40
        )

    def test_no_false_build_attestation(self):
        record = self.record()
        record["verificationResult"]["statement"]["predicate"]["githubBuildPerformed"] = True
        assert not app.matching_statement(
            [record], self.name, self.digest, app.sha256(self.checksum)
        )

    def test_signer_and_predicate_constraints(self):
        with patch.object(app.shutil, "which", return_value="/usr/bin/gh"), \
             patch.object(app, "run", return_value=json.dumps([self.record()])) as command:
            app.verify(self.checksum)
            self.assertIn("--signer-workflow", command.call_args.args)
            self.assertIn(app.SIGNER, command.call_args.args)
            self.assertIn(app.PREDICATE, command.call_args.args)

    def test_request_uses_exact_workflow_run_id(self):
        def command(*args, **kwargs):
            if args[:2] == ("git", "rev-parse"):
                return "a" * 40 + "\n"
            if args[:2] == ("git", "status"):
                return ""
            if args[:2] == ("gh", "api"):
                data = json.loads(kwargs["stdin"])
                self.assertTrue(data["return_run_details"])
                self.assertEqual(data["inputs"]["image_sha256"], self.digest)
                self.assertEqual(data["inputs"]["checksum_sha256"], app.sha256(self.checksum))
                return json.dumps({"workflow_run_id": 12345})
            if args[:3] == ("gh", "run", "view"):
                self.assertEqual(args[3], "12345")
                return json.dumps({"status": "completed", "conclusion": "success"})
            raise AssertionError(args)

        with patch.object(app.shutil, "which", return_value="/usr/bin/gh"), \
             patch.object(app, "run", side_effect=command), \
             patch.object(app, "verify") as verify:
            app.request(self.image, self.checksum)
            verify.assert_called_once_with(self.checksum, expected=self.name, commit="a" * 40)


if __name__ == "__main__":
    unittest.main()
