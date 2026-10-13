# Security reference documents

Local copies of the public standards that informed GnosisLab-VM's
security model, kept so readers can consult the source material
without hunting down external links.

## Vendored documents

| Document | Source | License / status | Retrieved |
|---|---|---|---|
| `NIST.SP.800-190.pdf` — Application Container Security Guide | <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf> | Public domain (US federal government work, 17 U.S.C. §105) | 2025-10 |
| `NIST.SP.800-53r5.pdf` — Security and Privacy Controls for Information Systems and Organizations, Rev. 5 | <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-53r5.pdf> | Public domain (17 U.S.C. §105) | 2025-10 |
| `NIST.SP.800-125A.pdf` — Security Recommendations for Server-based Hypervisor Platforms | <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-125A.pdf> | Public domain (17 U.S.C. §105) | 2025-10 |
| `NIST.SP.800-218.pdf` — Secure Software Development Framework (SSDF) v1.1 | <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-218.pdf> | Public domain (17 U.S.C. §105) | 2025-10 |
| `NIST.SP.800-207.pdf` — Zero Trust Architecture | <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-207.pdf> | Public domain (17 U.S.C. §105) | 2025-10 |
| `OWASP-Top-10-for-LLMs-v2025.pdf` — OWASP Top 10 for LLM Applications (2025) | <https://genai.owasp.org/llm-top-10/> | CC BY-SA 4.0 — redistributed verbatim with attribution to OWASP GenAI Security Project | 2025-10 |

## Referenced but not vendored

The following standards informed the project but are not included
because their license terms do not permit redistribution, or no
single distributable document exists:

- **CIS Benchmarks** (Docker, Linux distribution benchmarks) — free
  for individual use after registration at <https://www.cisecurity.org/>,
  but the license prohibits redistribution. Link-only.
- **DISA STIGs** (e.g., Ubuntu STIG) — public DoD documents, but
  distributed as XCCDF benchmark XML rather than readable documents.
  See <https://public.cyber.mil/stigs/>.
- **MITRE ATLAS** — adversarial-threat knowledge base for AI systems;
  a living website, not a document. <https://atlas.mitre.org/>
- **ISO/IEC 29147 & 30111** (vulnerability disclosure / handling) —
  ISO standards are commercial and cannot be bundled.
