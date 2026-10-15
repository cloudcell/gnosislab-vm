---
description: Upgrade OpenCode V2 using the official curl installer
---
Before doing anything, ask me for explicit confirmation to upgrade OpenCode and wait for my approval. If approved, run `/home/lab/.opencode/bin/opencode upgrade --method curl` as the `lab` user (never use sudo or npm). This GnosisLab-VM installation is provisioned using the official curl-style executable path, so explicitly pass `--method curl`; do not rely on autodetection.

If the command fails, show its actual stderr/stdout and do not claim success or attempt a fallback installation. After it succeeds, run `/home/lab/.opencode/bin/opencode --version` and report the installed version. Remind me to close and reopen the OpenCode TUI so its running process uses the updated binary. Do not change, regenerate, or overwrite OpenCode configuration, MCP servers, model providers, or reasoning variants.
