"""Regression test: the XFCE UTC clock helper must work with Bash nounset."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "deploy/labloop-panel-clock.sh"


class UTCClockTests(unittest.TestCase):
    def test_sets_and_verifies_utc_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "xfconf-query"
            log = Path(tmp) / "writes"
            stub.write_text("""#!/usr/bin/env bash
set -eu
if [[ " $* " == *" -lv "* ]]; then
    printf '/plugins/plugin-7 clock\\n'
elif [[ " $* " == *" -s "* ]]; then
    printf '%s\\n' "$*" >> "$WRITE_LOG"
elif [[ " $* " == *" -p "* ]]; then
    case "$*" in
        *timezone*) echo UTC ;;
        *digital-time-format*) echo '%H:%M UTC' ;;
        *) exit 1 ;;
    esac
fi
""")
            stub.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = tmp + os.pathsep + env["PATH"]
            env["WRITE_LOG"] = str(log)
            result = subprocess.run(["bash", str(SCRIPT)], env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("UTC clock: applied", result.stdout)
            self.assertIn("digital-time-format", log.read_text())
            self.assertIn("timezone", log.read_text())


if __name__ == "__main__":
    unittest.main()
