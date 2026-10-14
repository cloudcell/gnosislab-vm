#!/usr/bin/env python3
"""Configure VSCodium launchers without assuming the Debian desktop-file path.

Runs as root in the guest after apt has installed the 'codium' package.
Preserves vendor desktop entries by writing overrides under /usr/local.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
from pathlib import Path


WRAPPER = "/usr/local/bin/codium"
APPLICATIONS = "/usr/local/share/applications"


def configure(root: Path, package_files: list[str]) -> tuple[str, str]:
    """Install a basic-password-store wrapper and one desktop entry.

    `root` allows tests to exercise an artificial filesystem; launcher
    paths written into desktop files always refer to the live guest root.
    """
    binary = None
    for candidate in (
        "/usr/bin/codium",
        "/usr/share/codium/codium",
        "/usr/share/codium/bin/codium",
        "/opt/vscodium/codium",
    ):
        path = root / candidate.lstrip("/")
        if path.is_file() and os.access(path, os.X_OK):
            # Never wrap the wrapper itself on repeated provisioning.
            if path.resolve() != (root / WRAPPER.lstrip("/")).resolve():
                binary = candidate
                break
    if binary is None:
        raise RuntimeError("codium is installed but no usable executable was found")

    wrapper_path = root / WRAPPER.lstrip("/")
    wrapper_path.parent.mkdir(parents=True, exist_ok=True)
    wrapper_path.write_text(
        "#!/bin/sh\nexec " + shlex.quote(binary) +
        ' --password-store=basic "$@"\n',
        encoding="utf-8",
    )
    wrapper_path.chmod(0o755)

    candidates = sorted(
        path for path in package_files
        if path.startswith("/usr/share/applications/")
        and path.endswith(".desktop")
        and "url-handler" not in Path(path).name.lower()
        and (root / path.lstrip("/")).is_file()
    )
    desktop_dir = root / APPLICATIONS.lstrip("/")
    desktop_dir.mkdir(parents=True, exist_ok=True)

    if candidates:
        # Override the installed desktop entry with its original basename so
        # the menu and file associations still use their packaged metadata.
        source = candidates[0]
        body = (root / source.lstrip("/")).read_text(encoding="utf-8")
        body, count = re.subn(
            r'(?m)^Exec=(?:"[^"]+"|\S+)([^\r\n]*)$',
            lambda m: "Exec=" + WRAPPER + m.group(1),
            body,
        )
        if count == 0:
            raise RuntimeError(f"VSCodium desktop entry has no Exec field: {source}")
        body = re.sub(
            r"(?m)^TryExec=[^\r\n]*$",
            "TryExec=" + WRAPPER,
            body,
        )
        filename = Path(source).name
    else:
        # Recent VSCodium .deb variants do not all ship a desktop file.
        filename = "codium.desktop"
        body = (
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=VSCodium\n"
            "Comment=Code Editing. Redefined.\n"
            "Exec=" + WRAPPER + " %F\n"
            "TryExec=" + WRAPPER + "\n"
            "Icon=codium\n"
            "Terminal=false\n"
            "Categories=Development;IDE;TextEditor;\n"
            "StartupNotify=true\n"
        )
    desktop = desktop_dir / filename
    desktop.write_text(body, encoding="utf-8")
    desktop.chmod(0o644)
    return binary, str(desktop)


def main() -> None:
    result = subprocess.run(
        ["dpkg-query", "-L", "codium"],
        capture_output=True,
        text=True,
        check=True,
    )
    binary, desktop = configure(Path("/"), result.stdout.splitlines())
    print(f"Configured VSCodium: executable={binary}, desktop={desktop}")


if __name__ == "__main__":
    main()
