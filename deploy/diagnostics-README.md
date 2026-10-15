# GnosisLab VM diagnostics

Run these **inside the VM** as the `lab` user.

- `check-lab-ready.sh`: service/tool readiness and, when healthy, deeper checks.
- `security-battery.sh`: isolation tests (includes deliberately adversarial probes).
- `functional-battery.sh`: end-to-end execution tests that create temporary artifacts.

The security and functional batteries actively exercise containers, filesystem
permissions and limits. Only run them in a disposable test VM when you intend
to test those behaviors. Do not run as root. Their presence on the desktop
does not mean the trusted MCP service is healthy.

Additional diagnostic reports extracted from the pinned GnosisLab package
may appear here when the host artifact cache contains them.
