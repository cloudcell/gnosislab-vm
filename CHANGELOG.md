# Changelog

All notable changes to GnosisLab-VM + GnosisLab (formerly Lab Loop /
ml-labloop + ml-scientist) are
recorded here. Format follows [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
calendar-dated releases until a versioning scheme is adopted.
Entry timestamps are the commit time in **UTC**.

## [0.0.2] — 2026-10-14 — gnosislab package migration

### Changed

- **Trusted zone installs `gnosislab` from PyPI** — the MCP image no
  longer vendors a source checkout; it `uv pip install`s the pinned
  `gnosislab==<ver>` package (offline-capable from the prefetched
  wheelhouse). Service ports move from the old development block to
  **28050–28091** and are derived from the image's own `ports.env`
  everywhere — quadlet PublishPorts, the watchdog, readiness checks —
  so port values can never drift between the image and the wiring.
  Existing VMs migrate in place via
  `30-ensure-lab-tools.sh --rebuild-mcp-image`; older pre-package
  images keep working because their ports derive from
  `/opt/*/ports.env` and incompatible file pushes are skipped with a
  note rather than breaking the service. *(2026-10-14 05:44Z)*
- **Public repo is a flat single tree** — the `ml-scientist` source
  mirror is gone (the `gnosislab` package is the distribution
  channel), and the bundle contents now land at the repository root.
  `import-lab-vm.sh` moved to **`20-import-lab-vm.sh`** at the top
  level, alongside the other numbered workflow scripts.
  *(2026-10-14 06:39Z – 06:46Z)*
- **opencode 2.0.15** — driver-zone agent bump. *(2026-10-01 08:52Z)*
- **README** — new positioning section framing LabLoop as a
  persistent scientific loop (science → adaptation → meta-adaptation):
  self-improvement at the research-process level, without claiming
  the model rewrites its own weights. *(2026-09-30 04:36Z)*

### Added

- **Offline, reproducible template builds** —
  `selfbuild/prefetch-cache.sh` warms `~/.cache/labloop` (apt bundle,
  checksum-verified ISO, npm/vsix/deb artifacts, wheelhouses, image
  tarballs); `LABLOOP_OFFLINE=1 ./00-build-lab-template.sh` never
  fetches — missing artifacts fail at minute 0, not mid-install.
  Artifacts older than 24 h are stale and re-fetched; a transient,
  firewall-scoped HTTP endpoint on the NAT gateway serves the guest
  during the build, with the served MANIFEST verified against the
  local copy. *(2026-10-01 08:44Z – 10:16Z)*
- **Trusted-zone liveness watchdog** — `labloop-mcp-watchdog`
  (systemd timer + service under the `mcp` account) probes every MCP
  server's `/health`; probe ports come from `ports.env`, as does the
  `lab-cnt-mcp` quadlet's PublishPort block — no literals survive.
  `deploy/test-watchdog-ports.sh` verifies the derivation flow.
  *(2026-09-29 20:38Z – 20:46Z)*
- **`labloop-fault`** — a sanctioned, sudoers-pinned fault-injection
  lever for the trusted zone (stop/freeze the MCP container for
  resilience drills) without widening the general root surface.
  *(2026-10-01 07:08Z)*
- **`BUILD_REV` provenance stamp** — the MCP image records its
  revision and clean/dirty state (plus dirty file list and diff hash
  for dirty trees) where the status digests can prove it, not just
  report it. *(2026-09-30 14:22Z – 2026-10-02 01:07Z)*
- **Phase timing** — `00`/`01`/`02` and `create-lab-template` now
  print a per-phase elapsed-time table plus a TOTAL at exit — on
  failure too, so the phase that ate the time or died is visible.
  *(2026-10-14 06:29Z)*
- **Greeter display mode** — the LightDM `display-setup-script` hook
  renders the login screen at the configured resolution/refresh, and
  an `--fb`/`--panning` pair fixes pointer clamping at non-native
  sizes. *(2026-10-01 08:52Z)*
- **`docs-pub/`** — a public-curated documentation bundle now ships
  with the scientist surface. *(2026-09-30 04:51Z)*

### Fixed

- **Fractional EDID refresh rates** — nominal `75` Hz now accepts the
  actual `74.94` Hz mode (1 % tolerance) and custom modeline names in
  the readiness check. *(2026-10-01 11:49Z)*
- **vsix install cleanup** — `/tmp` cleanup runs as root so the
  `lab` user can delete sticky-bit files left by the install.
  *(2026-10-01 10:45Z)*
- **Cache-endpoint quoting** — `CACHE_URL` is quoted in every curl
  call so URLs with special characters can't break expansion.
  *(2026-10-01 10:16Z)*
- **Security battery expectation** — recognizes the sanctioned fault
  lever's sudo rule instead of flagging it. *(2026-10-02 01:07Z)*

### Removed

- **`ml-scientist` source mirror** — no longer staged into the public
  bundle; the `gnosislab` PyPI package is the sole public channel for
  the scientist. *(2026-10-14 06:39Z)*

## [0.0.1] — 2026-09-25 — first public release

### Added

- **Lab VM pipeline** — unattended Linux Mint 22.3 build
  (`00-build-lab-template.sh`), publish-mode sealing
  (`01-prepare-template-for-cloning.sh`), and per-user cloning
  (`02-create-vm-from-template.sh`) against KVM/libvirt.
  *(2026-09-21 21:23Z – 2026-09-22 16:11Z)*
- **Three-zone isolation** — driver (`lab`), trusted (`mcp`, the five
  ml-* MCP servers under rootless Podman), hostile (`exp`, confined
  experiment container: read-only rootfs, PID/memory caps, no route
  to MCP or host networks). *(2026-09-20 18:42Z)*
- **ml-scientist** — the five MCP servers (agora, arete, zetesis,
  episteme, anamnesis) with the commitments enforced structurally:
  falsifiability at admission, sealed-code bundles, programme-level
  state, tracked belief, and sandboxed execution that fails closed.
  *(ecosystem since 2026-09-13 14:24Z)*
- **Sanctioned data channels** — host-initiated over the QEMU guest
  agent only (no SSH, no virtiofs, no guest→host sockets):
  `80-ingest-lab-data.sh` pushes timestamped, immutable batches to a
  read-only `/incoming`; `90-extract-lab-data.sh` pulls manifest +
  sha256-verified tarballs staged in-guest by `labloop-export`.
  *(2026-09-23 21:20Z – 21:29Z)*
- **`30-ensure-lab-tools.sh`** — idempotent in-place tooling upgrade
  for existing VMs (wrappers, sudoers, quadlets, opencode config,
  guides, readiness check). *(2026-09-23 22:00Z)*
- **`11-release-template.sh`** — menu-driven promotion of a qcow2 +
  checksum from the private trials bucket to the public release
  bucket (`hf://buckets/cloudcell/LabLoop`). *(2026-09-25 04:18Z)*
- **GENESIS warmup run** — a full scientific cycle as an apparatus
  smoke test, ending with the agent writing a signed
  `*-ONBOARDING.md` note for future sessions.
  *(2026-09-23 23:03Z; steps 0 + 11: 2026-09-24 06:05Z–06:27Z)*
- **Trial interpreter** — `/srv/lab/trial-env` volume carrying
  numpy / pandas / scipy / scikit-learn / matplotlib; episteme's
  executor uses it via `ML_EPISTEME_EXECUTOR_PYTHON`.
  *(2026-09-24 21:01Z)*
- **`labloop-update-opencode`** — password-gated, semver-validated
  update path for the driver-zone agent (`autoupdate: false` keeps
  the pinned install authoritative). *(2026-09-24 04:58Z)*
- **Readiness warnings** — `check-lab-ready.sh` gains a WARN tier:
  opencode PATH-shadowing and version drift are reported without
  failing the run. *(2026-09-24 05:24Z)*
- **Trial access to ingested datasets** — `lab-cnt-mcp` now mounts
  `/srv/lab/incoming:/incoming:ro`, so episteme's executor sandbox
  (bwrap `--ro-bind / /`) can read host-ingested corpora without
  staging them through the exp-writable `/exchange`. Read-only at
  both the volume and namespace layers — verified fail-closed
  (write attempt → `EROFS`) on lab-vm-rc-4.
  *(2026-09-26 23:59Z)*

### Fixed

- **Display resolution silently unconfigured** — the virtio-XML
  hardening regex matched the NIC's `<model type='virtio'/>` before the
  video one, so the `<resolution>` child landed on the NIC and libvirt
  dropped it; the guest fell back to a default mode. The search is now
  anchored inside `<video>…</video>`. Resolution and refresh are now
  configurable via `labloop.conf` (`LABLOOP_RES_X/RES_Y`, default
  2560×1440; `LABLOOP_REFRESH`, any value 30–75 Hz including non-integer
  rates like 59.94). Rates absent from the virtio EDID are injected at
  login as a reduced-blanking modeline by `labloop-display.sh`
  (autostart). `check-lab-ready.sh` gained a `display-mode` check that
  verifies the active mode and refresh against the configured target.
  *(2026-09-26 22:20Z)*
- **QXL TTM wedge — second freeze on an already-enlarged
  framebuffer** — the video model is now `virtio` (virtio-gpu), which
  has no per-head TTM framebuffer to thrash; the QXL `vgamem` bump
  only delayed the wedge. New templates build with `--video virtio`;
  the XML hardening still resizes QXL for domains built before the
  switch. *(2026-09-26 19:10Z)*
- **Hostile-zone resource storm wedges the VM** — `lab-cnt-exp`
  was allowed `--cpus 6 --memory 16g` on an 8 vCPU / 16 GiB VM
  (no headroom for the desktop), and `labloop-exec` did not pin
  BLAS/OpenMP threading, so a single `import numpy` before
  `os.environ.setdefault("OMP_NUM_THREADS","1")` spawned 8 threads
  per worker — 86 runnable threads, load 58, display starved, hard
  freeze. Caps are now `--cpus 5 --cpu-shares 512 --memory 12g`
  (host tasks win under contention) and `labloop-exec` exports
  `OMP/OPENBLAS/MKL/NUMEXPR/VECLIB/BLIS_NUM_THREADS=1` into every
  exec. `30-ensure-lab-tools.sh` also now pushes `labloop-exec` +
  `labloop-build`, which it had silently never updated.
  *(2026-09-26 18:06Z)*
- **Display freezes** — QXL `vgamem` raised 32 → 128 MiB; at
  2560×1440 the starved framebuffer caused TTM thrashing until the
  DRM path wedged. *(2026-09-25 22:57Z)*
- **`design_experiment` race** — parallel calls both promoted the
  same hypothesis; the loser hit an illegal `under_test→under_test`
  transition after already creating its trial. Promotion is now
  atomic and idempotent. *(2026-09-24 20:57Z)*
- **Export staging on tmpfs** — `labloop-export` stages under
  `/var/lib` (survives reboots) instead of `/run`.
  *(2026-09-23 22:39Z)*
- **Guest-agent flakiness** — ingest/extract retry transient QGA
  transport failures and capture stderr. *(2026-09-23 22:20Z)*
- **Quadlet restarts** — `SuccessExitStatus` added so container
  exits don't wedge the services. *(2026-09-23 22:54Z)*

### Security

- Published images are **sealed**: `lab`/`exp` passwords locked; the
  importer mints a random one-time password for first login.
  *(sealing pipeline 2026-09-22 09:00Z; OTP import 2026-09-22 06:33Z)*
- `SECURITY-MANUAL.md` §8 documents the root-access model: bounded
  wrappers are lanes, not walls — the VM is the hard boundary.
  *(2026-09-24 05:17Z)*
