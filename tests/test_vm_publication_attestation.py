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
            commands = [c.args for c in command.call_args_list]
            self.assertIn(("gh", "attestation", "verify", "--help"), commands)
            verification = commands[-1]
            self.assertIn("--signer-workflow", verification)
            self.assertIn(app.SIGNER, verification)
            self.assertIn(app.PREDICATE, verification)

    def test_missing_or_outdated_gh_refuses_before_dispatch(self):
        with patch.object(app.shutil, "which", return_value=None), \
             patch.object(app, "run") as execute:
            with self.assertRaisesRegex(app.PublicationError, "missing"):
                app.request(self.image, self.checksum)
            execute.assert_not_called()
        with patch.object(app.shutil, "which", return_value="/usr/bin/gh"), \
             patch.object(app, "run", side_effect=app.PublicationError(
                 'gh failed (exit 1): unknown command "attestation" for "gh"'
             )) as execute:
            with self.assertRaisesRegex(app.PublicationError, "Upgrade gh"):
                app.request(self.image, self.checksum)
            execute.assert_called_once_with(
                "gh", "attestation", "verify", "--help", timeout=20
            )

    def test_signed_manifest_is_required_when_provided(self):
        manifest = self.checksum.with_name(self.name + ".provenance.json")
        with patch.object(app, "run", side_effect=[
            "a" * 40 + "\\n", "",
        ]):
            app.create_provenance(self.checksum, version="0.1.45")
        self.assertEqual(
            app.provenance_data(self.checksum, manifest)["software"]["versionEvidence"],
            "publisher-declared",
        )
        record = self.record()
        record["verificationResult"]["statement"]["subject"].append({
            "name": manifest.name,
            "digest": {"sha256": app.sha256(manifest)},
        })
        self.assertTrue(app.matching_statement(
            [record], self.name, self.digest, app.sha256(self.checksum),
            manifest_digest=app.sha256(manifest),
        ))
        self.assertFalse(app.matching_statement(
            [self.record()], self.name, self.digest, app.sha256(self.checksum),
            manifest_digest=app.sha256(manifest),
        ))
        with patch.object(app.shutil, "which", return_value="/usr/bin/gh"), \
             patch.object(app, "run", side_effect=[
                "help", json.dumps([record])
             ]):
            app.verify(self.checksum, provenance=manifest)

    def test_manifest_tampering_and_wrong_commit_rejected(self):
        with patch.object(app, "run", side_effect=["a" * 40 + "\\n", ""]):
            manifest = app.create_provenance(self.checksum, version="0.1.45")
        with self.assertRaises(app.PublicationError):
            app.provenance_data(self.checksum, manifest, commit="b" * 40)
        data = json.loads(manifest.read_text())
        data["image"]["sha256"] = "f" * 64
        manifest.write_text(json.dumps(data))
        with self.assertRaises(app.PublicationError):
            app.provenance_data(self.checksum, manifest)

    def test_build_recorded_version_and_mismatch_refusal(self):
        build = Path(self.temp.name) / "build-info.json"
        build.write_text(json.dumps({
            "schemaVersion": 1,
            "templateName": "lab-template-20261014T1230Z",
            "gnosislabVersion": "0.1.45",
            "vmBuilderCommit": "a" * 40,
        }))
        with patch.object(app, "run", side_effect=["b" * 40 + "\\n", ""]):
            manifest = app.create_provenance(self.checksum, build_info=build)
        data = app.provenance_data(self.checksum, manifest)
        self.assertEqual(data["software"]["gnosislabVersion"], "0.1.45")
        self.assertEqual(data["software"]["versionEvidence"], "builder-recorded")
        self.assertEqual(data["source"]["templateBuildCommit"], "a" * 40)
        with self.assertRaises(app.PublicationError):
            app.create_provenance(self.checksum, build_info=build, version="0.1.44")

    def test_missing_provenance_version_refused(self):
        with self.assertRaisesRegex(app.PublicationError, "version unknown"):
            app.create_provenance(self.checksum)

    def test_manifest_digest_dispatched_for_signature(self):
        with patch.object(app, "run", side_effect=["a" * 40 + "\\n", ""]):
            manifest = app.create_provenance(self.checksum, version="0.1.45")
        def command(*args, **kwargs):
            if args == ("gh", "attestation", "verify", "--help"):
                return "help"
            if args[:2] == ("git", "rev-parse"):
                return "a" * 40 + "\\n"
            if args[:2] == ("git", "status"):
                return ""
            if args[:2] == ("gh", "api"):
                data = json.loads(kwargs["stdin"])
                self.assertEqual(data["inputs"]["provenance_sha256"], app.sha256(manifest))
                return json.dumps({"workflow_run_id": 12345})
            if args[:3] == ("gh", "run", "view"):
                return json.dumps({"status": "completed", "conclusion": "success"})
            raise AssertionError(args)
        with patch.object(app.shutil, "which", return_value="/usr/bin/gh"), \
             patch.object(app, "run", side_effect=command), \
             patch.object(app, "verify") as verify:
            app.request(self.image, self.checksum, provenance=manifest)
            verify.assert_called_once_with(
                self.checksum, expected=self.name, commit="a" * 40, provenance=manifest,
            )

    def test_request_uses_exact_workflow_run_id(self):
        def command(*args, **kwargs):
            if args == ("gh", "attestation", "verify", "--help"):
                return "GitHub attestation verify help"
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
