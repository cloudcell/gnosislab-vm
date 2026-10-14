# GnosisLab-VM: Architecture, alternatives, and feature comparison

> **Status:** Comparative technical survey, 14 October 2026. **GnosisLab-VM is alpha software.** This is a review of publicly documented capabilities, not an independent penetration test, benchmark, vendor certification, or claim that any product is universally more secure.

[GnosisLab-VM](https://github.com/cloudcell/gnosislab-vm) is an optional VM-based environment for [GnosisLab](https://github.com/cloudcell/gnosislab), which supplies scientific research-process services. It combines a complete Linux research desktop with a KVM host boundary and distinct *driver*, *trusted scientific service*, and *untrusted experiment* zones. Most alternatives below concentrate on isolating agents or providing programmable execution infrastructure. They can be complementary to, rather than replacements for, the scientific runtime.

**Scope and interpretation:** A checkmark means the feature is supplied **natively and documented** for the stated product, **not** that the feature is identical in depth, quality, security, or default configuration. `🟡` means conditional, optional, partial, backend-dependent, or achievable with documented setup. `—` means not a native offering or insufficiently documented; it **does not** mean the feature is impossible. Unverified capabilities are not awarded a checkmark. Unless otherwise stated, “scientific verification” refers to GnosisLab's methodological and execution-evidence mechanisms, **not proof of scientific truth**.

## At a glance

| Product | Primary role | Typical isolation / runtime | Main advantage | Principal trade-off |
| --- | --- | --- | --- | --- |
| **[GnosisLab-VM](https://github.com/cloudcell/gnosislab-vm)** | Persistent protected scientific research environment | Full KVM/libvirt guest; rootless Podman inside guest | Scientific state plus dedicated experiment/agent separation and controlled transfers | Linux/KVM management; larger footprint; alpha |
| **[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)** | Agent sandbox and policy-control plane | Docker, Podman, Kubernetes or libkrun MicroVM | Kernel-level controls, credential mediation, policy verification, APIs | Scientific methods and research evidence must be integrated separately |
| **[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)** | Local or cloud AI coding-agent workstations | MicroVM per sandbox (local); managed cloud option | Integrated workspace/IDE workflow, agent tooling, network/credential/MCP mediation | General software-development focus; host-mounted workspaces require care |
| **[E2B](https://github.com/e2b-dev/E2B)** | Programmatic code/desktop sandboxes | Cloud-managed isolated environments / microVM infrastructure | Quick SDK-driven creation, code execution, desktop SDK, cloud scale | Cloud-oriented workflows and operating model |
| **[Daytona](https://www.daytona.io/docs/en/sandboxes/)** | Programmatic remote agent computers | Linux containers by default; optional VMs, GPU and macOS environments | SDKs, APIs, persistence, desktop access, network controls | Current managed offering; former OSS core [no longer maintained](https://github.com/daytonaio/daytona) |
| **[Kata Containers](https://github.com/kata-containers/kata-containers)** | VM-backed container runtime | Lightweight VMs integrated with container runtimes | Container workflow with VM boundaries | No built-in scientific research application |
| **[Firecracker](https://github.com/firecracker-microvm/firecracker)** | Minimal virtual machine monitor | KVM microVMs on Linux | Small overhead, programmatic VM building blocks | Requires orchestration and workload layers |
| **[gVisor](https://github.com/google/gvisor)** | Stronger isolation of container system calls | Userspace application kernel / `runsc` | Reduced direct host-kernel syscall exposure | Not a hypervisor-based full VM; app compatibility nuances |

> **Important taxonomy:** OpenShell, Docker Sandboxes, E2B and Daytona are products or platforms. Kata, Firecracker and gVisor are lower-level runtime components. Feature counts across these categories are not a fair ranking.

## Feature matrix: research and workflow differentiation

**Legend:** `✅` documented native feature; `🟡` partial, optional, or configuration-dependent; `—` not natively supplied or not substantiated. **Columns represent the named solution, without combining it with GnosisLab or arbitrary third-party packages.**

| Capability | GnosisLab-VM | OpenShell | Docker Sandboxes | E2B | Daytona |
| --- | :---: | :---: | :---: | :---: | :---: |
| Bundled GnosisLab scientific MCP runtime | ✅ | — | — | — | — |
| Scientific hypotheses, trials and research decisions as first-class state | ✅ | — | — | — | — |
| Scientific execution evidence and research-record reconciliation | ✅ | — | — | — | — |
| Methodological controls through GnosisLab | ✅ | — | — | — | — |
| Explicit trusted scientific-state vs untrusted experiment zones | ✅ | — | — | — | — |
| Preconfigured interactive Linux research desktop | ✅ | — | 🟡 | 🟡 | 🟡 |
| Persistent environments across sessions | ✅ | 🟡 | ✅ | 🟡 | ✅ |
| Reusable environment templates / images | ✅ | ✅ | ✅ | ✅ | ✅ |
| Host-initiated controlled import/export without a shared host workspace by default | ✅ | — | — | — | — |
| General-purpose agent execution (agent installed/configured) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Native scientific report validity guarantee | — | — | — | — | — |

The **distinctive integrated combination** is the first five rows: scientific-process services together with separately protected execution, not merely code sandboxing. GnosisLab-VM **does not orchestrate agents**, and its safeguards do not guarantee that an experiment or conclusion is scientifically correct. OpenShell and the other platforms can host or connect to GnosisLab with additional integration work.

## Feature matrix: isolation, security and operations

| Capability | GnosisLab-VM | OpenShell | Docker Sandboxes | E2B | Daytona |
| --- | :---: | :---: | :---: | :---: | :---: |
| VM / hypervisor boundary available | ✅ | 🟡 | ✅ | ✅ | 🟡 |
| Distinct rootless containers for trusted services and experiment code inside one guest | ✅ | — | — | — | — |
| Read-only root filesystem for untrusted experiment container | ✅ | 🟡 | 🟡 | 🟡 | 🟡 |
| Resource/process limits | ✅ | ✅ | ✅ | ✅ | ✅ |
| Network egress allowlist / deny-by-default policy | — | ✅ | ✅ | — | ✅ |
| Endpoint-restricted agent credential injection/mediation | — | ✅ | ✅ | — | — |
| Policy-change proof / formal policy analyzer | — | ✅ | — | — | — |
| Documented guest/agent command auditing or platform logs | ✅ | ✅ | 🟡 | 🟡 | ✅ |
| Local host-managed sandbox workflow | ✅ | ✅ | ✅ | — | — |
| Hosted / managed on-demand compute offering | — | 🟡 | ✅ | ✅ | ✅ |
| General-purpose SDK/API for sandbox lifecycle | — | ✅ | ✅ | ✅ | ✅ |
| Kubernetes-native management integration | — | ✅ | — | — | — |
| Locally managed sandbox runtime on Linux x86-64 host | ✅ | ✅ | ✅ | — | — |
| Locally managed sandbox runtime on Apple Silicon host | — | ✅ | ✅ | — | — |
| Local sandbox runtime on Windows host | — | 🟡 | ✅ | — | — |

**Why some cells are partial:** OpenShell’s VM boundary depends on selecting its MicroVM compute driver; its Docker/Podman modes do not provide a separate VM per workload by themselves. Docker Sandboxes and E2B include tools to build interactive/desktop experiences, but those are not the same as a shipped research desktop with protected scientific state. E2B and Daytona have controls and service options that depend on product tier or deployment; E2B is left unmarked for native egress allowlisting in this survey because current primary-source evidence was insufficient to verify it; this matrix only gives credit for documented native features. A `—` in a *local runtime* row does not mean that a Windows or Mac computer cannot connect to a hosted sandbox.

The GnosisLab-VM VM image may be booted under compatible Windows/macOS hypervisors after conversion or emulation, **but its build, clone, guest-agent data transfer and security verification scripts currently target x86-64 Linux/KVM/libvirt**. On Apple Silicon, the shipped x86-64 guest requires emulation; a native ARM64 guest is not supplied. No equivalent security validation has been published for non-KVM hosts. See the [README compatibility disclaimer](../README.md#running-without-kvm-virtualbox-macos).

## Platform compatibility: deployment versus remote access

These are **deployment** capabilities, not whether an SDK can call a remotely hosted service from a laptop. “VM image possible” is not equivalent to supported, validated local management.

| Platform or access mode | GnosisLab-VM | OpenShell | Docker Sandboxes | E2B | Daytona |
| --- | --- | --- | --- | --- | --- |
| Linux x86-64 local execution | **Supported KVM/libvirt tooling** | Supported Docker/Podman/MicroVM | Local microVM supported | Remote service; self-hosting possible separately | Remote managed service |
| Linux ARM64 local execution | No native guest/build support documented | Supported | Check local platform requirements | Remote service | Remote service |
| Windows x86-64 local execution | Converted x86-64 image may boot in a compatible hypervisor; Linux management scripts unavailable | WSL2 experimental | Local sandbox support | Remote SDK/client | Remote SDK/client |
| Intel macOS local execution | Converted x86-64 image may boot in compatible hypervisor; not validated | Not in current host support matrix | Check local platform requirements | Remote SDK/client | Remote SDK/client |
| Apple Silicon macOS local execution | Shipped x86-64 image requires emulation; no native ARM64 build | Supported | Supported | Remote SDK/client | Remote SDK/client |
| Kubernetes or hosted fleet management | Not packaged | Supported Kubernetes compute driver | Docker cloud service available | Cloud API; separate self-hosting components | Managed platform |

All host/guest combinations require an appropriate compatible hypervisor, hardware and security configuration. The [OpenShell support matrix](https://docs.nvidia.com/openshell/latest/about/support-matrix) identifies precise tested versions and Linux kernel requirements. Docker local and cloud offerings have separate policy/control paths. GnosisLab-VM's explicit host support caveat remains in its [README](../README.md#running-without-kvm-virtualbox-macos).

### Lower-level isolation components

| Capability | Kata Containers | Firecracker | gVisor |
| --- | :---: | :---: | :---: |
| VM/hypervisor-backed isolation | ✅ | ✅ | — |
| OCI/container integration | ✅ | 🟡 | ✅ |
| Designed for dense programmatic isolated workloads | ✅ | ✅ | ✅ |
| Complete agent gateway and credential mediation | — | — | — |
| Prebuilt scientific research desktop | — | — | — |
| Scientific hypotheses, evidence and methodology runtime | — | — | — |
| Complete experiment-to-publication provenance system | — | — | — |

None of these three is a direct one-for-one replacement for GnosisLab-VM. They are candidate *substrates* for a future optional execution backend.

## GnosisLab-VM architecture and trust boundaries

```text
Linux/KVM host (QEMU/libvirt)
  |  Builds, scrubs and clones VM templates
  |  Host-initiated import/export via QEMU guest agent
  v
Disposable Linux research VM
  +-- DRIVER: lab (VSCodium/OpenCode/agent, interactive tools)
  |     Calls GnosisLab MCP services; agent is not intrinsically trusted
  +-- TRUSTED: mcp (rootless Podman)
  |     GnosisLab scientific services and durable state
  +-- EXPERIMENT: exp (restricted rootless Podman)
        Read-only rootfs, dropped capabilities, resource caps,
        constrained filesystem mounts, private/loopback network fence,
        *public internet egress allowed by present policy*
```

The host hypervisor provides a different boundary from the in-guest process, user and container controls. In-guest root compromise can undo those internal divisions. Agent code and experiment-produced files must be considered untrusted even after successful transfer. Both VM escape risk and management interfaces require patching and scrutiny. See [guest security rules](../deploy/SECURITY-MANUAL.md), [security gaps](../deploy/SECURITY-COMPLIANCE-NOTE.md) and [data movement](../deploy/DATA-MOVEMENT-MANUAL.md).

### What the science layer adds

Conventional sandboxes answer questions such as **“Where did this process run, and what was it permitted to access?”** GnosisLab adds **“Which hypothesis or methodological obligation did this run address; what evidence was captured; and does the stored research record reconcile with observed execution?”** It provides structured scientific process controls and evidence provenance, but not a guarantee of reproducibility, validity, compliance, or scientific truth. These controls reside in the [GnosisLab core project](https://github.com/cloudcell/gnosislab), not in the hypervisor itself.

## GnosisLab-VM vs NVIDIA OpenShell: deeper technical comparison

| Dimension | GnosisLab-VM today | NVIDIA OpenShell today | Practical consequence |
| --- | --- | --- | --- |
| Unit of isolation | Full Linux VM containing multiple separately privileged internal zones | Individual agent sandbox under selectable Docker/Podman/Kubernetes/MicroVM runtime | Different trust models; choosing OpenShell MicroVM narrows the VM-boundary difference |
| Main protected asset | Scientific state and research workflow, alongside host isolation | Host data, credentials, network and permitted tool access | Complementary assets |
| Agent control | IDE/CLI agents execute in `lab` guest identity | Supervisor mediates agent process, filesystem, syscalls and network | OpenShell is more granular around the agent |
| Scientific state | Five GnosisLab services in trusted `mcp` zone | No bundled GnosisLab state service | GnosisLab-VM excels in end-to-end research workflow |
| Generated code | Separate restricted `exp` container reached through `labloop-exec` | Agent workload runs in restricted sandbox | Different separation of research-agent and experiment code |
| Network | Experiment zone blocks loopback/private addresses; allows public destinations | Detailed policy-controlled network access, default-deny rules and credential-aware providers | OpenShell has finer-grained egress control |
| Credentials | Protected guest locations; no documented general request-time provider proxy | Trusted supervisor adds provider credentials to approved requests | OpenShell better protects provider keys from hostile agents |
| Policy verification | Readiness and security test batteries; no formal general policy prover | Policy prover checks specified policy changes | A formal policy proof is not a general security proof |
| Export | Guest staging, host pull, manifest/hash/size validation, untrusted artifact warning | APIs and mounts / runtime-specific transfer | GnosisLab-VM has an explicit scientific-lab data handoff procedure |
| Management | Numbered scripts, libvirt, guest agent | Gateway, CLI, gRPC and several SDKs | OpenShell scales better across heterogeneous runtime fleets |
| Platform model | Linux/KVM host for official tooling; converted disk for other hosts | Linux, Apple Silicon macOS; Windows WSL2 experimental | OpenShell is easier to deploy across workstation operating systems |
| Status | Alpha | Versioned stable and development releases; release qualification is explicitly scoped | Neither constitutes universal security certification |

### Risks currently documented by GnosisLab-VM

1. **Permissive public egress.** Experiment processes can reach public endpoints. They cannot be assumed unable to exfiltrate data simply because secrets are intended to remain outside their container. In particular, deliberately imported scientific datasets may be readable inside it.
2. **Shared driver identity.** Agent processes share the `lab` user in the interactive driver zone. The project's own compliance note discusses exposure of typed credentials in an X11 session and recommends splitting agent and human identities as an escalation option.
3. **MCP access from the driver.** Trusted services listen on guest loopback and the shipped design does not rely on bearer authentication for every local driver client. This is consistent with its documented trust model, but should not be mistaken for arbitrary-agent isolation.
4. **Artifact handling.** Hashes protect transfer integrity, not semantic safety or producer authenticity. Extracted files can contain hostile content; no automatic content scanning is claimed.
5. **Supply-chain hardening.** Some base images are version-tagged rather than content-digest pinned, as the project's own security gap note records.
6. **Non-KVM portability.** Booting a VMDK/OVA under VirtualBox or VMware is not equivalent to passing the KVM-oriented functional and isolation tests.

These limitations do **not** establish that an alternative vendor is immune to comparable vulnerabilities. They identify documented design gaps and test obligations relevant to the GnosisLab-VM threat model.

## Which solution fits which problem?

| Requirement | Best starting point | Reason |
| --- | --- | --- |
| Research desktop with protected scientific-process state and separate experiment execution | **GnosisLab-VM** | Integrated scientific control and desktop VM |
| Untrusted coding agent that needs secrets, web services and narrow network policy | **OpenShell** or **Docker Sandboxes** | Granular network and credential mediation |
| Hosted code-interpreter or desktop session created programmatically | **E2B** | Cloud-first developer APIs |
| Remote programmable workstations with mixed compute types | **Daytona** | Managed sandbox computers and SDKs |
| Replacing container isolation with lightweight VM boundaries | **Kata Containers** | VM-backed OCI runtime integration |
| Building a custom high-density Linux microVM service | **Firecracker** | Minimal KVM-based VMM |
| Restricting syscalls for traditional OCI workloads | **gVisor** | Userspace application kernel |

No category implies a general security or performance ranking. Suitability depends on the workload, threat model, patch levels, tenancy, costs and operator controls.

## Recommended development priorities for GnosisLab-VM

| Priority | Improvement | Why it matters | Acceptance evidence |
| --- | --- | --- | --- |
| **P0** | Per-workspace egress policy with an optional **default-deny** mode | Limits unauthorized destinations and protects sensitive inputs | Automated blocked-destination, DNS, bypass, IPv6 and dependency-install tests |
| **P0** | Agent/driver identity separation and mediated credentials | Reduces agent access to human credentials and trusted state | No privileged credential readable by test agent; documented impersonation tests |
| **P1** | An optional credential/inference proxy outside the hostile workload | Grants tightly scoped provider access without disclosing raw keys | Tests for header injection, host validation and credential leakage |
| **P1** | Digest-pinned images, signed manifests and reproducible release attestations | Tightens image supply-chain assurances | CI verification of immutable inputs and published provenance |
| **P1** | Publish a security and compatibility conformance matrix by host/hypervisor | Makes “boots” vs “supported” explicit | Repeatable functional and security results for each supported host |
| **P1** | Scan/quarantine/export policy for outputs | Reduces artifact-borne attack paths | Tests for path traversal, archive bombs, content types and restricted export |
| **P2** | A small documented GnosisLab deployment contract for other sandboxes | Keeps the scientific layer independent of one virtualization stack | End-to-end example using an independent execution backend |
| **P2** | Optional lifecycle API / management daemon | Improves headless multi-workspace workflows | Stable interface, authorization and idempotent lifecycle tests |

The infrastructure should remain deliberately small. A new general-purpose sandbox orchestrator is unnecessary unless a concrete user scenario demonstrates that existing runtimes cannot host the scientific layer.

## Positioning

> **GnosisLab-VM is a virtualized scientific research environment that separates agent-operated workspaces, trusted scientific-process services and potentially untrusted experiment execution.** It combines GnosisLab's evidence-oriented scientific workflow with a disposable full-VM deployment. It does not orchestrate AI agents and does not guarantee scientific truth or complete containment.

For general agent containment, OpenShell and Docker Sandboxes have more elaborate ready-made network/credential controls. GnosisLab-VM's distinctive contribution is *research-process integrity together with isolated execution*. Future integrations with alternative sandbox backends would broaden deployment without diluting that contribution.

## Sources and maintenance

**Source snapshot:** reviewed 14 October 2026. Provider documentation and feature availability can change; verify when making purchasing or security decisions.

- GnosisLab-VM: [README](../README.md), [security manual](../deploy/SECURITY-MANUAL.md), [security compliance note](../deploy/SECURITY-COMPLIANCE-NOTE.md), [data movement](../deploy/DATA-MOVEMENT-MANUAL.md), [workflow](../WORKFLOW.md).
- GnosisLab research runtime: [core repository](https://github.com/cloudcell/gnosislab).
- NVIDIA OpenShell: [repository](https://github.com/NVIDIA/OpenShell), [support matrix](https://docs.nvidia.com/openshell/latest/about/support-matrix), [runtimes](https://docs.nvidia.com/openshell/latest/how-it-works/sandboxes/runtimes), [policy prover](https://docs.nvidia.com/openshell/latest/how-it-works/policies/prover).
- Docker Sandboxes: [overview](https://docs.docker.com/ai/sandboxes/), [architecture](https://docs.docker.com/ai/sandboxes/architecture/), [network policy](https://docs.docker.com/ai/sandboxes/governance/access-controls/local/), [credentials](https://docs.docker.com/ai/sandboxes/configuration/credentials).
- E2B: [repository](https://github.com/e2b-dev/E2B), [documentation](https://docs.e2b.dev/), [self-hosting runtime](https://github.com/e2b-dev/runtime).
- Daytona: [current sandboxes](https://www.daytona.io/docs/en/sandboxes/), [network controls](https://www.daytona.io/docs/en/network-limits/), [historical repository notice](https://github.com/daytonaio/daytona).
- Kata Containers: [repository](https://github.com/kata-containers/kata-containers).
- Firecracker: [repository](https://github.com/firecracker-microvm/firecracker).
- gVisor: [repository](https://github.com/google/gvisor).

**Method:** capability cells are based on first-party documentation and the GnosisLab-VM repository. They reflect shipped/documented integration, not theoretical possibility, feature parity testing, or superiority scores. Proposed features are **not** marked as present. If a cell is stale or insufficiently supported, please open an issue with a dated primary-source reference.
