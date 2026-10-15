"""Reject incomplete GnosisLab template sealing and cloning."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD = (ROOT / "create-lab-template").read_text()
SEAL = (ROOT / "01-prepare-template-for-cloning.sh").read_text()
CLONE = (ROOT / "02-create-vm-from-template.sh").read_text()
MARKER = "/etc/gnosislab-vm/template-ready"
VALUE = "gnosislab-vm-template-ready-v1"


class TemplateCompleteness(unittest.TestCase):
    def test_marker_is_written_only_after_batteries(self):
        self.assertIn(MARKER, BUILD)
        self.assertIn(VALUE, BUILD)
        self.assertGreater(BUILD.index('note "recording completed template provisioning"'),
                           BUILD.index('note "functional battery'))
        self.assertLess(BUILD.index('note "recording completed template provisioning"'),
                        BUILD.index('note "shutdown"'))

    def test_seal_checks_marker_before_sysprep(self):
        self.assertIn(MARKER, SEAL)
        self.assertIn(VALUE, SEAL)
        self.assertLess(SEAL.index('note "verifying completed template before sealing"'),
                        SEAL.index('note "virt-sysprep'))

    def test_clone_checks_marker_before_clone_is_created(self):
        self.assertIn(MARKER, CLONE)
        self.assertIn(VALUE, CLONE)
        self.assertLess(CLONE.index('note "verifying complete GnosisLab template"'),
                        CLONE.index('sudo virt-clone --original'))


if __name__ == "__main__":
    unittest.main()
