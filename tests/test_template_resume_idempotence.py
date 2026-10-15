"""Template resume reuses verified images and scientific environments."""
from pathlib import Path
import unittest
B=(Path(__file__).resolve().parents[1]/"create-lab-template").read_text()
class ResumeTests(unittest.TestCase):
    def test_image_digests_not_only_mutable_tags(self):
        self.assertIn("image_archive_config_id", B)
        self.assertIn("cached image identities already match; skipping large downloads", B)
        self.assertIn("podman image inspect", B)
    def test_existing_trial_env_not_destroyed(self):
        self.assertIn("trial_env_ready()", B)
        self.assertIn("existing scientific trial-env verified; reuse without modification", B)
        self.assertIn("test -f /srv/lab/trial-env/pyvenv.cfg", B)
        self.assertNotIn("uv venv --clear", B)
        self.assertIn('trial_env_ready || die "trial-env failed scientific import verification"', B)
if __name__=="__main__":
    unittest.main()
