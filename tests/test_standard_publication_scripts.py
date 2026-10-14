"""Standard numbered publishing entry points own recovery and backfill."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StandardPublicationScripts(unittest.TestCase):
    def test_script_10_resumes_existing_sealed_image_without_resealing(self):
        text = (ROOT / "10-upload-template-to-hf.sh").read_text()
        self.assertIn('if [ "${1:-}" = "--existing" ]; then', text)
        self.assertIn('OUT="$(realpath "$EXISTING")"', text)
        self.assertIn('if [ -z "$EXISTING" ]; then', text)
        self.assertLess(
            text.index('if [ -z "$EXISTING" ]; then'),
            text.index('LABLOOP_PUBLISH=1 ./01-prepare-template-for-cloning.sh'),
        )
        self.assertIn('sha256sum -c "$(basename "$OUT").sha256"', text)
        self.assertIn('provenance-check', text)
        self.assertIn('--provenance "$OUT.provenance.json"', text)
        self.assertIn('"$HF" buckets cp "$OUT.provenance.json"', text)

    def test_script_11_backfills_without_reuploading_qcow2(self):
        text = (ROOT / "11-release-template.sh").read_text()
        self.assertIn('--backfill) BACKFILL=1', text)
        self.assertIn('if [ "$BACKFILL" -eq 1 ]; then', text)
        self.assertIn('cmp -s "$SIDECAR" "$remote_tmp/$NAME.sha256"', text)
        self.assertIn('--provenance "$MANIFEST"', text)
        self.assertIn('"$HF" buckets cp "$MANIFEST" "$DST/$NAME.provenance.json"', text)
        self.assertLess(
            text.index('if [ "$BACKFILL" -eq 1 ]; then'),
            text.index('note "listing $SRC"'),
        )
        self.assertLess(
            text.index('echo "==> signed JSON provenance published; QCOW2 and checksum unchanged"'),
            text.index('# pick the image'),
        )
        self.assertIn('"$DST" = "hf://buckets/cloudcell/LabLoop"', text)
        self.assertIn('cmp -s "$MANIFEST" "$remote_tmp/$NAME.provenance.json"', text)

    def test_readme_advertises_only_standard_numbered_entry_points(self):
        text = (ROOT / "README.md").read_text()
        self.assertIn('10-upload-template-to-hf.sh', text)
        self.assertIn('11-release-template.sh', text)
        self.assertIn('--backfill', text)
        self.assertIn('--existing', text)
        doc = (ROOT / "docs-pub/VM-PUBLICATION-ATTESTATION.md").read_text()
        self.assertNotIn('scripts/resume-vm-trial-upload.sh', doc)


if __name__ == "__main__":
    unittest.main()
