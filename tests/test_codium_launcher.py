"""Regression tests for Codium desktop entry and VSIX cache handling."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "create-lab-template"
MODULE_PATH = ROOT / "deploy/configure-codium.py"
SPEC = importlib.util.spec_from_file_location("configure_codium", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def make_bin(root: Path, location: str = "/usr/bin/codium") -> Path:
    binary = root / location.lstrip("/")
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text("#!/bin/sh\nexit 0\n")
    binary.chmod(0o755)
    return binary


class CodiumLauncherTests(unittest.TestCase):
    def test_missing_vendor_desktop_file_creates_working_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_bin(root)
            executable, desktop = MODULE.configure(root, ["/usr/bin/codium"])
            self.assertEqual(executable, "/usr/bin/codium")
            entry = Path(desktop).read_text()
            self.assertIn("Exec=/usr/local/bin/codium %F", entry)
            self.assertIn("TryExec=/usr/local/bin/codium", entry)
            wrapper = (root / "usr/local/bin/codium").read_text()
            self.assertIn("exec /usr/bin/codium --password-store=basic", wrapper)
            self.assertIn('"$@"', wrapper)
            self.assertEqual((root / "usr/local/bin/codium").stat().st_mode & 0o777, 0o755)

    def test_vendor_desktop_entry_is_preserved_and_overridden(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_bin(root)
            vendor = root / "usr/share/applications/codium.desktop"
            vendor.parent.mkdir(parents=True)
            source = (
                "[Desktop Entry]\n"
                "Name=VSCodium\n"
                "Exec=/usr/share/codium/codium --reuse-window %F\n"
                "TryExec=/usr/share/codium/codium\n"
                "[Desktop Action NewWindow]\n"
                "Name=New Window\n"
                "Exec=/usr/share/codium/codium --new-window %U\n"
            )
            vendor.write_text(source)
            binary, desktop = MODULE.configure(root, ["/usr/share/applications/codium.desktop"])
            self.assertEqual(binary, "/usr/bin/codium")
            self.assertEqual(vendor.read_text(), source)
            override = Path(desktop).read_text()
            self.assertIn("Exec=/usr/local/bin/codium --reuse-window %F", override)
            self.assertIn("Exec=/usr/local/bin/codium --new-window %U", override)
            self.assertIn("TryExec=/usr/local/bin/codium", override)

    def test_no_codium_executable_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, "no usable executable"):
                MODULE.configure(Path(tmp), [])

    def test_rerun_is_idempotent_and_never_wraps_itself(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_bin(root)
            first = MODULE.configure(root, [])
            second = MODULE.configure(root, [])
            self.assertEqual(first, second)
            self.assertNotIn("/usr/local/bin/codium --password-store=basic",
                             (root / "usr/local/bin/codium").read_text())

    def test_alternate_package_binary_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_bin(root, "/usr/share/codium/codium")
            executable, _ = MODULE.configure(root, [])
            self.assertEqual(executable, "/usr/share/codium/codium")


class VsixCacheTests(unittest.TestCase):
    def test_cached_vsix_selection_is_single_and_version_aware(self):
        script = TEMPLATE.read_text()
        self.assertIn("for extension in ZooCodeOrganization.zoo-code tomoki1207.pdf", script)
        self.assertIn('sort -V | tail -n 1', script)
        with tempfile.TemporaryDirectory() as tmp:
            for name in (
                "ZooCodeOrganization.zoo-code-3.85.100541.vsix",
                "ZooCodeOrganization.zoo-code-3.89.100615.vsix",
                "ZooCodeOrganization.zoo-code-3.89.100617.vsix",
                "tomoki1207.pdf-1.2.2.vsix",
            ):
                (Path(tmp) / name).touch()
            cmd = (
                'for ext in ZooCodeOrganization.zoo-code tomoki1207.pdf; do '
                'find "$1" -maxdepth 1 -type f -name "$ext-*.vsix" '
                "-printf '%f\\n' | sort -V | tail -n 1; "
                'done'
            )
            result = subprocess.run(
                ["bash", "-c", cmd, "bash", tmp],
                check=True, text=True, capture_output=True,
            )
            self.assertEqual(result.stdout.splitlines(), [
                "ZooCodeOrganization.zoo-code-3.89.100617.vsix",
                "tomoki1207.pdf-1.2.2.vsix",
            ])


if __name__ == "__main__":
    unittest.main()
