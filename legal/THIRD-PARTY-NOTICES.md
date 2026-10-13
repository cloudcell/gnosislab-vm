# Third-Party Notices

GnosisLab-VM includes third-party components that are licensed separately from
GnosisLab-VM. These components remain under their respective licenses.

Unless otherwise stated, original GnosisLab-VM code and documentation are
licensed under the Apache License 2.0. Third-party components are not
relicensed under the GnosisLab-VM Apache-2.0 license. They are included,
distributed, or referenced under the terms of their own licenses.

This file is provided for attribution and license-notice purposes. It is not a
substitute for the full license texts included with each third-party component.

## Components fetched during image construction

The GnosisLab-VM build pipeline downloads and installs the following components
into the lab VM template. Their license texts ship inside the built image.

### uv

- License: Apache License 2.0 OR MIT License
- Copyright: Astral
- Installed by: `containers/experiment/Containerfile` (pinned release)

### micromamba

- License: BSD 3-Clause License
- Copyright: QuantStack / mamba contributors
- Installed by: `containers/experiment/Containerfile` (pinned release)

### VSCodium

- License: MIT License
- Copyright: VSCodium contributors; built from Microsoft's MIT-licensed
  vscode sources
- Installed by: `create-lab-template` (VSCodium deb repository)

### opencode

- License: MIT License
- Copyright: SST / opencode contributors
- Installed by: `create-lab-template` (npm package `@opencode/cli`, pinned)

## Operating system and distribution packages

The guest image is built on Linux Mint (Ubuntu/Debian base) and installs
distribution packages including Podman (Apache-2.0), nftables (GPL-2.0), and
TeX Live (LPPL and assorted free licenses). Operating-system packages retain
their own licenses and ship their copyright files inside the image under
`/usr/share/doc/<package>/copyright`.

The `python:3.12-slim` container base image is used for the experiment and MCP
containers; it contains Debian packages and the Python runtime (PSF license),
each under its own license.

## Bundled assets

Any third-party fonts, icons, or similar assets vendored directly into this
repository carry their own license files alongside the asset.

## Vendored reference documents

`docs-pub/reference/` ships local copies of external security standards cited
by `deploy/SECURITY-COMPLIANCE-NOTE.md`:

- **NIST SP 800-190**, *Application Container Security Guide* (2017)
- **NIST SP 800-53 Rev. 5**, *Security and Privacy Controls for Information
  Systems and Organizations* (2020)
- **NIST SP 800-125A**, *Security Recommendations for Server-based Hypervisor
  Platforms* (2018)
- **NIST SP 800-218**, *Secure Software Development Framework (SSDF) v1.1*
  (2022)
- **NIST SP 800-207**, *Zero Trust Architecture* (2020)
- **OWASP Top 10 for LLM Applications** (2025 edition)

The five NIST publications are works of the United States federal government
and are therefore in the **public domain** (17 U.S.C. §105); no license terms
apply and redistribution is unrestricted. The OWASP document is distributed
under **Creative Commons BY-SA 4.0** and is included verbatim with attribution
to the OWASP GenAI Security Project (© OWASP Foundation); the document itself
remains under CC BY-SA 4.0. Source URLs and retrieval date are recorded in
`docs-pub/reference/README.md`.

The following are deliberately *not* vendored and are referenced by link only:

- **CIS Benchmarks** (Docker and Linux distribution benchmarks) — the CIS
  license prohibits redistribution
- **DISA STIGs** — public DoD documents, but distributed as XCCDF benchmark
  XML rather than readable publications
- **MITRE ATLAS** — a living knowledge-base website, not a distributable
  document
- **ISO/IEC 29147 and 30111** — commercial ISO standards
