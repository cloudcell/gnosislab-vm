#!/usr/bin/env bash
# Trusted-zone supervisor: starts all five ml-* servers.
# If any server exits the container exits too — fail closed
# (a-00 §5.11): a partially-up MCP zone must never look healthy.
set -euo pipefail
cd /opt/gnosislab
set -a; source ./ports.env; set +a

# Feature 7B: the experimental-code executor shares this container with
# trusted scientific state. It MUST sandbox trial state and networking.
# Do not silently run the historical GnosisLab 0.1.42 executor here.
export ML_EPISTEME_TRIAL_ISOLATION=enforced
export ML_EPISTEME_SANDBOX=full
python3 - <<'PY'
from pathlib import Path
from ml_episteme_mcp.clients.local_executor import LocalExecutor

try:
    ex = LocalExecutor(sandbox="full", trace_reads="off")
    assert getattr(ex, "_vm_isolation", False), "unpatched trial executor"
    args = ex._sandbox_argv(["/bin/true"], None, Path("/opt/gnosislab/ports.env"))
    assert "--unshare-net" in args and "--unshare-pid" in args
    assert ["--tmpfs", "/state"] == args[args.index("--tmpfs", args.index("--tmpfs") + 1):
                                         args.index("--tmpfs", args.index("--tmpfs") + 1) + 2] \
        if args.count("--tmpfs") > 1 else False
except Exception as exc:
    raise SystemExit(
        "FATAL: GnosisLab VM trial isolation unavailable; "
        "install a verified GnosisLab release containing Feature 7B "
        f"before starting trusted services ({exc})"
    ) from exc
PY

mkdir -p /state/logs

start() { # <name> <port-var> <gui-var>
    local name="$1" port="${!2}" gui="${!3}"
    "ml-${name}-mcp" \
        --transport http --host 0.0.0.0 --port "$port" \
        --stateless --observability-port "$gui" --log-tool-args \
        >>"/state/logs/${name}.log" 2>&1 &
    echo "started ml-${name}-mcp :${port} (gui :${gui}) pid $!"
}

# upstreams first — agora's startup integrity check flags every
# channel that isn't answering yet, and the violation row persists
# in the check log until the next interval (looks like an outage on
# the dashboard). Gate on their /health so agora starts into a
# fully-connected lab.
start arete     ML_ARETE_PORT     ML_ARETE_GUI_PORT
start zetesis   ML_ZETESIS_PORT   ML_ZETESIS_GUI_PORT

# Trial interpreter: images built after 2026-09-24 carry /opt/trial-env
# (numpy & co.) for episteme's executor. Older images lack it — only
# override the interpreter when the env actually exists, or every
# trial would fail to spawn.
if [ -x /opt/trial-env/bin/python ]; then
    export ML_EPISTEME_EXECUTOR_PYTHON=/opt/trial-env/bin/python
fi
start episteme  ML_EPISTEME_PORT  ML_EPISTEME_GUI_PORT
start anamnesis ML_ANAMNESIS_PORT ML_ANAMNESIS_GUI_PORT

for url in "127.0.0.1:${ML_ARETE_PORT}" "127.0.0.1:${ML_ZETESIS_PORT}" \
           "127.0.0.1:${ML_EPISTEME_PORT}" "127.0.0.1:${ML_ANAMNESIS_PORT}"; do
    for _ in $(seq 60); do
        curl -sf "http://${url}/health" >/dev/null 2>&1 && break
        sleep 1
    done
done

start agora     ML_AGORA_PORT     ML_AGORA_GUI_PORT

wait -n
echo "FATAL: an ml-* server exited; stopping container" >&2
exit 1
